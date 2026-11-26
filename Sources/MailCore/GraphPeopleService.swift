import Foundation
import CalendarCore

// MARK: - People: Outlook contacts, directory users, relevance (/me/people)
//
// Checked on learn.microsoft.com (2026-11-20):
//  * `GET /me/contactFolders`, `GET /me/contacts`, `GET /me/contactFolders/{id}/contacts`, `POST /me/contacts`,
//    `POST /me/contactFolders/{id}/contacts`, `PATCH /me/contacts/{id}`, `DELETE /me/contacts/{id}`: delegated
//    Contacts.ReadWrite. Another user's shared folder: `GET /users/{id|upn}/contacts` with Contacts.Read(Write).Shared.
//  * `GET /users/{id|userPrincipalName}` and `GET /users?$filter=mail in (…)`: User.ReadBasic.All is enough for the
//    basic profile (id, displayName, mail, jobTitle, department, officeLocation, businessPhones, mobilePhone).
//    `mail` supports `$filter` with `eq` and `in` (user resource page).
//  * `GET /users/{id}/photos/{size}/$value`: 404 when the user has no photo.
//  * `GET /me/people`: People.Read, relevance-ranked; mixes organisation users with personal and implicit (external)
//    contacts, told apart by `personType.subclass` (`OrganizationUser` = in the organisation). Only those are kept.
// UNVERIFIED against a tenant:
//  * `GET /users/{id}/manager` with only User.ReadBasic.All (Learn lists User.Read.All as least privileged for other
//    users' managers) → a 403 is treated as "no manager shown", never an error;
//  * the size limit of `in (…)` on `/users` (15 per request used here, the documented directory-object limit for
//    some properties);
//  * that `/me/people` ids are directory object ids for internal people.
//
// Nothing here is persisted: contacts, profiles and photos live in memory only (no new plaintext cache). Photos are
// fetched on an ephemeral session without a URLCache, so they never touch disk.

public struct ContactFolder: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public init(id: String, displayName: String) { self.id = id; self.displayName = displayName }
}

public struct Contact: Sendable, Hashable, Identifiable {
    public var id: String
    public var folderId: String?
    /// Owner of a shared contact folder (nil = mine).
    public var owner: String?
    public var displayName: String
    public var givenName: String
    public var surname: String
    public var emails: [EmailAddress]
    public var businessPhones: [String]
    public var mobilePhone: String?
    public var jobTitle: String?
    public var department: String?
    public var companyName: String?
    public init(id: String = "", folderId: String? = nil, owner: String? = nil, displayName: String = "",
                givenName: String = "", surname: String = "", emails: [EmailAddress] = [], businessPhones: [String] = [],
                mobilePhone: String? = nil, jobTitle: String? = nil, department: String? = nil, companyName: String? = nil) {
        self.id = id; self.folderId = folderId; self.owner = owner; self.displayName = displayName
        self.givenName = givenName; self.surname = surname; self.emails = emails; self.businessPhones = businessPhones
        self.mobilePhone = mobilePhone; self.jobTitle = jobTitle; self.department = department; self.companyName = companyName
    }
    public var primaryAddress: String? { emails.first?.address }
    public var bestName: String {
        if !displayName.isEmpty { return displayName }
        let n = [givenName, surname].filter { !$0.isEmpty }.joined(separator: " ")
        return n.isEmpty ? (primaryAddress ?? "(no name)") : n
    }

    /// Graph JSON for create / update. Only fields the editor owns; `nil` optionals are sent as null on update so a
    /// cleared field clears on the server.
    public func graphBody() -> [String: Any] {
        func orNull(_ s: String?) -> Any { (s?.isEmpty ?? true) ? NSNull() : s! }
        return [
            "displayName": bestName == "(no name)" ? "" : bestName,
            "givenName": givenName, "surname": surname,
            "emailAddresses": emails.map { ["name": $0.name, "address": $0.address] },
            "businessPhones": businessPhones,
            "mobilePhone": orNull(mobilePhone), "jobTitle": orNull(jobTitle),
            "department": orNull(department), "companyName": orNull(companyName),
        ]
    }
}

public struct DirectoryPerson: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var mail: String?
    public var userPrincipalName: String?
    public var jobTitle: String?
    public var department: String?
    public var officeLocation: String?
    public var businessPhones: [String]
    public var mobilePhone: String?
    public init(id: String, displayName: String, mail: String? = nil, userPrincipalName: String? = nil,
                jobTitle: String? = nil, department: String? = nil, officeLocation: String? = nil,
                businessPhones: [String] = [], mobilePhone: String? = nil) {
        self.id = id; self.displayName = displayName; self.mail = mail; self.userPrincipalName = userPrincipalName
        self.jobTitle = jobTitle; self.department = department; self.officeLocation = officeLocation
        self.businessPhones = businessPhones; self.mobilePhone = mobilePhone
    }
    public var address: String? { mail ?? userPrincipalName }
}

public protocol PeopleService: Sendable {
    func contactFolders() async throws -> [ContactFolder]
    /// `folderId` nil = the default Contacts folder. `owner` nil = mine; else a user who shared their contacts.
    func contacts(folderId: String?, owner: String?) async throws -> [Contact]
    func createContact(_ c: Contact, folderId: String?) async throws -> Contact
    func updateContact(_ c: Contact) async throws -> Contact
    func deleteContact(id: String) async throws
    /// Relevance-ranked people (/me/people).
    func relevantPeople(top: Int) async throws -> [DirectoryPerson]
    /// One directory user by address (mail, then UPN). nil = not in the directory (external).
    func directoryUser(address: String) async throws -> DirectoryPerson?
    /// Batch address → directory object id (internal people only; misses are absent from the result).
    func directoryIds(addresses: [String]) async throws -> [String: String]
    func manager(userId: String) async throws -> DirectoryPerson?
    /// Photo bytes (memory only). nil = no photo.
    func photo(userId: String) async throws -> Data?
}

// MARK: - Merge (contacts + directory + CommGraph correspondents)

public struct PersonEntry: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable, CaseIterable { case contact, directory, correspondent }
    /// Lowercased address, or "contact:<id>" for a contact without an address.
    public var id: String
    public var displayName: String
    public var address: String?
    public var directoryId: String?
    public var contactIds: [String]
    public var jobTitle: String?
    public var department: String?
    public var company: String?
    public var sources: Set<Source>
    /// Messages exchanged (CommGraph), for ranking. 0 when unknown.
    public var messageCount: Int
    public var isInternal: Bool
    public init(id: String, displayName: String, address: String?, directoryId: String? = nil, contactIds: [String] = [],
                jobTitle: String? = nil, department: String? = nil, company: String? = nil, sources: Set<Source>,
                messageCount: Int = 0, isInternal: Bool = false) {
        self.id = id; self.displayName = displayName; self.address = address; self.directoryId = directoryId
        self.contactIds = contactIds; self.jobTitle = jobTitle; self.department = department; self.company = company
        self.sources = sources; self.messageCount = messageCount; self.isInternal = isInternal
    }
}

public enum PeopleMerge {
    /// One row per address. Names: contact > directory > CommGraph. Directory rows are internal by definition.
    public static func merge(contacts: [Contact], directory: [DirectoryPerson], correspondents: [PersonNode]) -> [PersonEntry] {
        var out: [String: PersonEntry] = [:]
        var order: [String] = []
        func upsert(_ key: String, _ make: () -> PersonEntry, _ update: (inout PersonEntry) -> Void) {
            if out[key] == nil { out[key] = make(); order.append(key) } else { update(&out[key]!) }
        }
        for c in contacts {
            let key = c.primaryAddress?.lowercased() ?? "contact:\(c.id)"
            upsert(key, {
                PersonEntry(id: key, displayName: c.bestName, address: c.primaryAddress, contactIds: [c.id],
                            jobTitle: c.jobTitle, department: c.department, company: c.companyName, sources: [.contact])
            }, { e in
                e.contactIds.append(c.id); e.sources.insert(.contact)
            })
        }
        for d in directory {
            guard let a = d.address?.lowercased(), !a.isEmpty else { continue }
            upsert(a, {
                PersonEntry(id: a, displayName: d.displayName, address: d.address, directoryId: d.id, jobTitle: d.jobTitle,
                            department: d.department, sources: [.directory], isInternal: true)
            }, { e in
                e.directoryId = d.id; e.sources.insert(.directory); e.isInternal = true
                if e.jobTitle == nil { e.jobTitle = d.jobTitle }
                if e.department == nil { e.department = d.department }
            })
        }
        for p in correspondents where p.bulk == 0 || p.toThem.n > 0 {   // skip newsletters nobody writes to
            let a = p.address.lowercased()
            guard a.contains("@") else { continue }
            upsert(a, {
                PersonEntry(id: a, displayName: p.displayName, address: p.address, company: p.company,
                            sources: [.correspondent], messageCount: p.total.n, isInternal: p.isInternal)
            }, { e in
                e.sources.insert(.correspondent); e.messageCount = p.total.n
                e.isInternal = e.isInternal || p.isInternal
                if e.company == nil { e.company = p.company }
            })
        }
        return order.compactMap { out[$0] }.sorted {
            let a = $0.displayName.lowercased(), b = $1.displayName.lowercased()
            return a == b ? $0.id < $1.id : a < b
        }
    }

    /// Filter by a free-text query over name, address, company, department.
    public static func filter(_ people: [PersonEntry], query: String) -> [PersonEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return people }
        return people.filter { p in
            [p.displayName, p.address ?? "", p.company ?? "", p.department ?? ""].contains { $0.lowercased().contains(q) }
        }
    }
}

// MARK: - Graph implementation

public final class GraphPeopleService: PeopleService, @unchecked Sendable {
    private let http: GraphHTTP
    private let photoHTTP: GraphHTTP
    static let contactSelect = "id,parentFolderId,displayName,givenName,surname,emailAddresses,businessPhones,mobilePhone,jobTitle,department,companyName"
    static let userSelect = "id,displayName,mail,userPrincipalName,jobTitle,department,officeLocation,businessPhones,mobilePhone"
    /// `$filter=mail in (…)` chunk (UNVERIFIED limit, see header).
    static let inChunk = 15

    /// `token`: Contacts.ReadWrite(.Shared) + People.Read + User.ReadBasic.All (`Auth.peopleScopes`), silent only.
    public init(token: @escaping GraphHTTP.TokenProvider, session: URLSession = .shared, photoSession: URLSession? = nil) {
        http = GraphHTTP(token: token, session: session)
        photoHTTP = GraphHTTP(token: token, session: photoSession ?? Self.ephemeralSession())
    }

    static func ephemeralSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    private func pages<T: Decodable>(_ first: URL, max: Int = 10, headers: [String: String] = [:]) async throws -> [T] {
        var out: [T] = []
        var next: URL? = first
        var n = 0
        while let u = next, n < max {
            let page: GHPage<T> = try await http.get(u, headers: headers)
            out += page.value; next = page.nextLink.flatMap(URL.init(string:)); n += 1
        }
        return out
    }

    public func contactFolders() async throws -> [ContactFolder] {
        let rows: [GHContactFolder] = try await pages(http.url("me/contactFolders", ["$top": "100", "$select": "id,displayName"]))
        return rows.map { ContactFolder(id: $0.id, displayName: $0.displayName ?? "") }
    }

    public func contacts(folderId: String?, owner: String?) async throws -> [Contact] {
        let root = owner.map { "users/\($0)" } ?? "me"
        let path = folderId.map { "\(root)/contactFolders/\($0)/contacts" } ?? "\(root)/contacts"
        let rows: [GHContact] = try await pages(http.url(path, ["$top": "200", "$select": Self.contactSelect, "$orderby": "displayName"]))
        return rows.map { $0.model(owner: owner) }
    }

    public func createContact(_ c: Contact, folderId: String?) async throws -> Contact {
        let path = folderId.map { "me/contactFolders/\($0)/contacts" } ?? "me/contacts"
        let body = try JSONSerialization.data(withJSONObject: c.graphBody())
        let data = try await http.send(http.url(path), method: "POST", body: body, idempotent: false)
        do { return try JSONDecoder().decode(GHContact.self, from: data).model(owner: nil) }
        catch { throw MailServiceError.http(201, "decode") }
    }

    public func updateContact(_ c: Contact) async throws -> Contact {
        guard c.owner == nil else { throw MailServiceError.forbidden }   // shared folders are read-only here
        let body = try JSONSerialization.data(withJSONObject: c.graphBody())
        let data = try await http.send(http.url("me/contacts/\(c.id)"), method: "PATCH", body: body, idempotent: true)
        do { return try JSONDecoder().decode(GHContact.self, from: data).model(owner: nil) }
        catch { throw MailServiceError.http(200, "decode") }
    }

    public func deleteContact(id: String) async throws {
        try await http.send(http.url("me/contacts/\(id)"), method: "DELETE", body: nil, idempotent: true)
    }

    public func relevantPeople(top: Int) async throws -> [DirectoryPerson] {
        let page: GHPage<GHRelevantPerson> = try await http.get(http.url("me/people", [
            "$top": String(top), "$select": "id,displayName,scoredEmailAddresses,jobTitle,department,userPrincipalName,personType",
        ]))
        // Only organisation users are directory people; /me/people also returns personal / implicit (external) contacts.
        return page.value.compactMap { p in
            guard let id = p.id, p.personType?.subclass == "OrganizationUser" else { return nil }
            return DirectoryPerson(id: id, displayName: p.displayName ?? "", mail: p.scoredEmailAddresses?.first?.address,
                                   userPrincipalName: p.userPrincipalName, jobTitle: p.jobTitle, department: p.department)
        }
    }

    public func directoryUser(address: String) async throws -> DirectoryPerson? {
        let a = address.lowercased()
        let q = a.replacingOccurrences(of: "'", with: "''")
        let page: GHPage<GHDirUser> = try await http.get(http.url("users", ["$filter": "mail eq '\(q)'", "$select": Self.userSelect]))
        if let u = page.value.first { return u.model }
        do {
            let u: GHDirUser = try await http.get(http.url("users/\(a)", ["$select": Self.userSelect]))
            return u.model
        } catch MailServiceError.notFound { return nil }
    }

    public func directoryIds(addresses: [String]) async throws -> [String: String] {
        let unique = Array(Set(addresses.map { $0.lowercased() }.filter { $0.contains("@") })).sorted()
        var out: [String: String] = [:]
        for start in stride(from: 0, to: unique.count, by: Self.inChunk) {
            let chunk = unique[start..<min(start + Self.inChunk, unique.count)]
            let list = chunk.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            let page: GHPage<GHDirUser> = try await http.get(http.url("users", [
                "$filter": "mail in (\(list))", "$select": "id,mail,userPrincipalName", "$top": "\(Self.inChunk)",
            ]))
            for u in page.value {
                if let m = u.mail?.lowercased(), chunk.contains(m) { out[m] = u.id }
                if let p = u.userPrincipalName?.lowercased(), chunk.contains(p) { out[p] = u.id }
            }
        }
        return out
    }

    public func manager(userId: String) async throws -> DirectoryPerson? {
        do {
            let u: GHDirUser = try await http.get(http.url("users/\(userId)/manager", ["$select": Self.userSelect]))
            return u.model
        } catch MailServiceError.notFound { return nil }
        catch MailServiceError.forbidden { return nil }
    }

    public func photo(userId: String) async throws -> Data? {
        do {
            return try await photoHTTP.send(photoHTTP.url("users/\(userId)/photos/96x96/$value"), method: "GET", body: nil,
                                            idempotent: true)
        } catch MailServiceError.notFound { return nil }
    }
}

// MARK: DTOs

struct GHContactFolder: Decodable { var id: String; var displayName: String? }
struct GHContact: Decodable {
    struct E: Decodable { var name: String?; var address: String? }
    var id: String; var parentFolderId: String?; var displayName: String?; var givenName: String?; var surname: String?
    var emailAddresses: [E]?; var businessPhones: [String]?; var mobilePhone: String?; var jobTitle: String?
    var department: String?; var companyName: String?
    func model(owner: String?) -> Contact {
        Contact(id: id, folderId: parentFolderId, owner: owner, displayName: displayName ?? "", givenName: givenName ?? "",
                surname: surname ?? "",
                emails: (emailAddresses ?? []).compactMap { e in e.address.map { EmailAddress(name: e.name ?? "", address: $0) } },
                businessPhones: businessPhones ?? [], mobilePhone: mobilePhone, jobTitle: jobTitle, department: department,
                companyName: companyName)
    }
}
struct GHRelevantPerson: Decodable {
    struct A: Decodable { var address: String? }
    var id: String?; var displayName: String?; var scoredEmailAddresses: [A]?; var jobTitle: String?; var department: String?
    var userPrincipalName: String?
    struct T: Decodable { var `class`: String?; var subclass: String? }
    var personType: T?
}
struct GHDirUser: Decodable {
    var id: String; var displayName: String?; var mail: String?; var userPrincipalName: String?; var jobTitle: String?
    var department: String?; var officeLocation: String?; var businessPhones: [String]?; var mobilePhone: String?
    var model: DirectoryPerson {
        DirectoryPerson(id: id, displayName: displayName ?? mail ?? "", mail: mail, userPrincipalName: userPrincipalName,
                        jobTitle: jobTitle, department: department, officeLocation: officeLocation,
                        businessPhones: businessPhones ?? [], mobilePhone: mobilePhone)
    }
}

// MARK: - Fixtures (synthetic, never the network)

public final class FixturePeopleService: PeopleService, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Contact]
    private var next = 100
    public static let directory: [DirectoryPerson] = [
        DirectoryPerson(id: "u-ada", displayName: "Ada Lovelace", mail: "ada@contoso.example", jobTitle: "Head of Engineering",
                        department: "Engineering", officeLocation: "Zürich", businessPhones: ["+41 44 000 00 01"]),
        DirectoryPerson(id: "u-grace", displayName: "Grace Hopper", mail: "grace@contoso.example", jobTitle: "Principal Engineer",
                        department: "Engineering", officeLocation: "Zug", mobilePhone: "+41 79 000 00 02"),
        DirectoryPerson(id: "u-alan", displayName: "Alan Turing", mail: "alan@contoso.example", jobTitle: "Research Lead",
                        department: "Research", officeLocation: "Basel"),
    ]

    public init() {
        store = [
            "c-1": Contact(id: "c-1", folderId: "f-default", displayName: "Marie Curie", givenName: "Marie", surname: "Curie",
                           emails: [EmailAddress(name: "Marie Curie", address: "marie@fabrikam.example")],
                           businessPhones: ["+41 31 000 00 03"], jobTitle: "Chief Scientist", companyName: "Fabrikam"),
            "c-2": Contact(id: "c-2", folderId: "f-default", displayName: "Ada Lovelace", givenName: "Ada", surname: "Lovelace",
                           emails: [EmailAddress(name: "Ada", address: "ada@contoso.example")], mobilePhone: "+41 79 000 00 01"),
        ]
    }

    public func contactFolders() async throws -> [ContactFolder] { [ContactFolder(id: "f-default", displayName: "Contacts")] }
    public func contacts(folderId: String?, owner: String?) async throws -> [Contact] {
        if owner != nil { return [Contact(id: "s-1", owner: owner, displayName: "Shared Person", emails: [EmailAddress(name: "", address: "shared@contoso.example")])] }
        return lock.withLock { store.values.sorted { $0.bestName < $1.bestName } }
    }
    public func createContact(_ c: Contact, folderId: String?) async throws -> Contact {
        lock.withLock {
            var c = c; next += 1; c.id = "c-\(next)"; c.folderId = folderId ?? "f-default"; store[c.id] = c; return c
        }
    }
    public func updateContact(_ c: Contact) async throws -> Contact {
        try lock.withLock { guard store[c.id] != nil else { throw MailServiceError.notFound }; store[c.id] = c; return c }
    }
    public func deleteContact(id: String) async throws { _ = lock.withLock { store.removeValue(forKey: id) } }
    public func relevantPeople(top: Int) async throws -> [DirectoryPerson] { Array(Self.directory.prefix(top)) }
    public func directoryUser(address: String) async throws -> DirectoryPerson? {
        Self.directory.first { $0.mail?.lowercased() == address.lowercased() }
    }
    public func directoryIds(addresses: [String]) async throws -> [String: String] {
        var out: [String: String] = [:]
        for a in addresses { if let u = try await directoryUser(address: a) { out[a.lowercased()] = u.id } }
        return out
    }
    public func manager(userId: String) async throws -> DirectoryPerson? { userId == "u-ada" ? nil : Self.directory[0] }
    public func photo(userId: String) async throws -> Data? { nil }
}
