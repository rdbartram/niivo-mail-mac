#include <cxxabi.h>
#include <cstdio>
#include <cstdlib>
// niivo MIP bridge implementation. See niivo_mipbridge.h for the contract and docs/MIP.md for the design.
//
// Learn references:
//  * rpmsg inspection (FileHandler::InspectAsync -> MsgInspector):
//    https://learn.microsoft.com/information-protection/develop/concept-email#file-sdk-operations-for-rpmsg-files
//  * cache storage types (InMemory): https://learn.microsoft.com/information-protection/develop/concept-cache-storage
//  * auth delegate: https://learn.microsoft.com/information-protection/develop/concept-authentication-cpp
//  * access checks / rights: https://learn.microsoft.com/information-protection/develop/concept-accesscheck
#include "niivo_mipbridge.h"

// SDK types keep default visibility so exception typeinfo (mip::Error & co.) matches the SDK dylibs.
#pragma GCC visibility push(default)
#include <mip/common_types.h>
#include <mip/diagnostic_configuration.h>
#include <mip/error.h>
#include <mip/logger_delegate.h>
#include <mip/mip_configuration.h>
#include <mip/mip_context.h>
#include <mip/stream_utils.h>
#include <mip/file/file_engine.h>
#include <mip/file/file_handler.h>
#include <mip/file/file_profile.h>
#include <mip/file/msg_inspector.h>
#include <mip/protection/protection_handler.h>
// Policy SDK (UPE): label policy for mail/meetings and label metadata + audit (ABI 1 additions).
#include <mip/upe/action.h>
#include <mip/upe/execution_state.h>
#include <mip/upe/label.h>
#include <mip/upe/metadata_action.h>
#include <mip/upe/metadata_entry.h>
#include <mip/upe/policy_engine.h>
#include <mip/upe/policy_handler.h>
#include <mip/upe/policy_profile.h>
#pragma GCC visibility pop

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

// ---- delegates -------------------------------------------------------------------------------------------------

/// Swallows every log line: MIP logs can contain user addresses, URLs and content identifiers, and the default
/// logger writes <state>/mip/logs/mip_sdk.miplog to disk.
class NullLogger final : public mip::LoggerDelegate {
public:
    void Init(const std::string&) override {}
    void Flush() override {}
    void WriteToLog(const mip::LogLevel, const std::string&, const std::string&, const std::string&, const int32_t) override {}
};

/// We never accept consent prompts for unknown service URLs; only the RMS / sync endpoints configured in Entra apply.
class RejectConsent final : public mip::ConsentDelegate {
public:
    mip::Consent GetUserConsent(const std::string&) override { return mip::Consent::Reject; }
};

class CallbackAuth final : public mip::AuthDelegate {
public:
    CallbackAuth(nmb_token_cb cb, void* user) : mCb(cb), mUser(user) {}
    bool AcquireOAuth2Token(const mip::Identity&, const OAuth2Challenge& ch, OAuth2Token& token) override {
        mCalls.fetch_add(1);
        std::vector<char> buf(16 * 1024, 0);
        int rc = mCb(mUser, ch.GetAuthority().c_str(), ch.GetResource().c_str(), ch.GetScope().c_str(),
                     ch.GetClaims().c_str(), buf.data(), buf.size());
        if (rc == NMB_ERR_CLAIMS_CHALLENGE) mClaims.store(true);
        if (rc != NMB_OK || buf[0] == 0) { std::memset(buf.data(), 0, buf.size()); return false; }
        buf[buf.size() - 1] = 0;
        token.SetAccessToken(std::string(buf.data()));
        std::memset(buf.data(), 0, buf.size());
        return true;
    }
    int calls() const { return mCalls.load(); }
    bool sawClaims() const { return mClaims.load(); }
    void reset() { mCalls.store(0); mClaims.store(false); }
private:
    nmb_token_cb mCb;
    void* mUser;
    std::atomic<int> mCalls{0};
    std::atomic<bool> mClaims{false};
};

// ---- promise observers -----------------------------------------------------------------------------------------

template <class T> using Promise = std::promise<std::shared_ptr<T>>;

class ProfileObserver final : public mip::FileProfile::Observer {
public:
    void OnLoadSuccess(const std::shared_ptr<mip::FileProfile>& p, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::FileProfile>>(c)->set_value(p);
    }
    void OnLoadFailure(const std::exception_ptr& e, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::FileProfile>>(c)->set_exception(e);
    }
    void OnAddEngineSuccess(const std::shared_ptr<mip::FileEngine>& e, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::FileEngine>>(c)->set_value(e);
    }
    void OnAddEngineFailure(const std::exception_ptr& e, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::FileEngine>>(c)->set_exception(e);
    }
};

class HandlerObserver final : public mip::FileHandler::Observer {
public:
    void OnCreateFileHandlerSuccess(const std::shared_ptr<mip::FileHandler>& h, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::FileHandler>>(c)->set_value(h);
    }
    void OnCreateFileHandlerFailure(const std::exception_ptr& e, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::FileHandler>>(c)->set_exception(e);
    }
    void OnInspectSuccess(const std::shared_ptr<mip::FileInspector>& i, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::FileInspector>>(c)->set_value(i);
    }
    void OnInspectFailure(const std::exception_ptr& e, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::FileInspector>>(c)->set_exception(e);
    }
};

// ---- helpers ---------------------------------------------------------------------------------------------------

struct Timeout {};

template <class T>
std::shared_ptr<T> await(std::future<std::shared_ptr<T>>& f, int seconds) {
    if (f.wait_for(std::chrono::seconds(seconds > 0 ? seconds : 60)) != std::future_status::ready) throw Timeout{};
    return f.get();
}

/// Exception → code. Never looks at what(): MIP error text can carry addresses / URLs.
int classify(const std::exception_ptr& ep, const CallbackAuth* auth) {
    if (auth && auth->sawClaims()) return NMB_ERR_CLAIMS_CHALLENGE;
    try { std::rethrow_exception(ep); }
    catch (const Timeout&) { return NMB_ERR_TIMEOUT; }
    catch (const mip::Error& e) {
        // Content-free diagnostic: error type number + extended code (no what(), no message text).
        if (std::getenv("NIIVO_MIP_DIAG")) {
            std::string code;
            // Debug-info keys only (values can hold URLs/addresses), plus the error class name.
            try { for (const auto& kv : e.GetDebugInfo()) { if (!code.empty()) code += "|"; code += kv.first;
                if (kv.first.find("code") != std::string::npos || kv.first.find("Code") != std::string::npos
                    || kv.first.find("HttpStatus") != std::string::npos || kv.first.find("status") != std::string::npos) code += "=" + kv.second; } } catch (...) {}
            code = e.GetErrorName() + " " + code;
            std::fprintf(stderr, "[MIPDIAG] type=%u code=%s\n", static_cast<unsigned>(e.GetErrorType()), code.c_str());
        }
        switch (e.GetErrorType()) {
            case mip::ErrorType::NO_PERMISSIONS: return NMB_ERR_NO_PERMISSION;
            case mip::ErrorType::ACCESS_DENIED:
            case mip::ErrorType::DISABLED_SERVICE: return NMB_ERR_ACCESS_DENIED;
            case mip::ErrorType::NO_AUTH_TOKEN:
            case mip::ErrorType::PROXY_AUTH_ERROR: return NMB_ERR_AUTH;
            case mip::ErrorType::NETWORK_ERROR: return NMB_ERR_NETWORK;
            case mip::ErrorType::BAD_INPUT_ERROR:
            case mip::ErrorType::NOT_SUPPORTED_OPERATION:
            case mip::ErrorType::CONTENT_FORMAT_NOT_SUPPORTED: return NMB_ERR_BAD_INPUT;
            case mip::ErrorType::CONSENT_DENIED: return NMB_ERR_CONSENT;
            case mip::ErrorType::OPERATION_CANCELLED: return NMB_ERR_TIMEOUT;
            default: return NMB_ERR_INTERNAL;
        }
    }
    catch (const std::exception& e) {
        if (std::getenv("NIIVO_MIP_DIAG")) {
            const auto* ti = abi::__cxa_current_exception_type();
            std::fprintf(stderr, "[MIPDIAG] std::exception type=%s\n", ti ? ti->name() : "?");
            // mip::Error compiled into the SDK may not match our typeinfo (separate dylib): try dynamic_cast.
            if (auto me = dynamic_cast<const mip::Error*>(&e))
                std::fprintf(stderr, "[MIPDIAG] via dynamic_cast mip type=%u name=%s\n", static_cast<unsigned>(me->GetErrorType()), me->GetErrorName().c_str());
        }
        return NMB_ERR_INTERNAL;
    }
    catch (...) {
        if (std::getenv("NIIVO_MIP_DIAG")) {
            const auto* ti = abi::__cxa_current_exception_type();
            std::fprintf(stderr, "[MIPDIAG] non-std exception type=%s\n", ti ? ti->name() : "?");
        }
        return NMB_ERR_INTERNAL;
    }
}

char* dupstr(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p) { std::memcpy(p, s.data(), s.size()); p[s.size()] = 0; }
    return p;
}

void zero(std::vector<uint8_t>& v) { if (!v.empty()) std::memset(v.data(), 0, v.size()); }

} // namespace

struct nmb_ctx {
    std::shared_ptr<mip::MipContext> context;
    std::shared_ptr<mip::FileProfile> profile;
    std::shared_ptr<mip::FileEngine> engine;
    std::shared_ptr<CallbackAuth> auth;
    // Lazily created by nmb_policy_load / nmb_label_compute (needs the policy-sync token, not just RMS).
    std::string user;
    int cacheType = NMB_CACHE_IN_MEMORY;
    std::shared_ptr<mip::PolicyProfile> policyProfile;
    std::shared_ptr<mip::PolicyEngine> policyEngine;
    std::mutex policyLock;
};

namespace {

class PolicyProfileObserver final : public mip::PolicyProfile::Observer {
public:
    void OnLoadSuccess(const std::shared_ptr<mip::PolicyProfile>& p, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::PolicyProfile>>(c)->set_value(p);
    }
    void OnLoadFailure(const std::exception_ptr& e, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::PolicyProfile>>(c)->set_exception(e);
    }
    void OnAddEngineSuccess(const std::shared_ptr<mip::PolicyEngine>& e, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::PolicyEngine>>(c)->set_value(e);
    }
    void OnAddEngineFailure(const std::exception_ptr& e, const std::shared_ptr<void>& c) override {
        std::static_pointer_cast<Promise<mip::PolicyEngine>>(c)->set_exception(e);
    }
};

/// Throws on failure (caller classifies). Reuses the context's MipContext and token callback.
void ensurePolicyEngine(nmb_ctx* ctx, int timeout_sec) {
    std::lock_guard<std::mutex> g(ctx->policyLock);
    if (ctx->policyEngine) return;
    const auto storage = ctx->cacheType == NMB_CACHE_ON_DISK_ENCRYPTED ? mip::CacheStorageType::OnDiskEncrypted
                                                                       : mip::CacheStorageType::InMemory;
    if (!ctx->policyProfile) {
        mip::PolicyProfile::Settings ps(ctx->context, storage, std::make_shared<PolicyProfileObserver>());
        auto pp = std::make_shared<Promise<mip::PolicyProfile>>();
        auto pf = pp->get_future();
        mip::PolicyProfile::LoadAsync(ps, pp);
        ctx->policyProfile = await(pf, timeout_sec);
    }
    mip::PolicyEngine::Settings es(mip::Identity(ctx->user), ctx->auth, /*clientData*/ "", "en-US");
    auto ep = std::make_shared<Promise<mip::PolicyEngine>>();
    auto ef = ep->get_future();
    ctx->policyProfile->AddEngineAsync(es, ep);
    ctx->policyEngine = await(ef, timeout_sec);
}

/// "key=value\n" lines -> entries (MSIP metadata keys/values never contain newlines).
std::vector<mip::MetadataEntry> parseMetadata(const char* text) {
    std::vector<mip::MetadataEntry> out;
    if (!text) return out;
    std::string s(text);
    size_t start = 0;
    while (start < s.size()) {
        size_t nl = s.find('\n', start);
        std::string line = s.substr(start, nl == std::string::npos ? std::string::npos : nl - start);
        auto eq = line.find('=');
        if (eq != std::string::npos && eq > 0) out.emplace_back(line.substr(0, eq), line.substr(eq + 1), 0u);
        if (nl == std::string::npos) break;
        start = nl + 1;
    }
    return out;
}

/// Execution state for an outgoing mail / meeting (content format "email"). Label values only, no content.
class EmailState final : public mip::ExecutionState {
public:
    std::shared_ptr<mip::Label> label;
    std::vector<mip::MetadataEntry> metadata;
    std::string contentId;
    bool justified = false;
    std::string justification;
    mip::AssignmentMethod method = mip::AssignmentMethod::PRIVILEGED;

    std::shared_ptr<mip::Label> GetNewLabel() const override { return label; }
    std::string GetContentIdentifier() const override { return contentId; }
    std::pair<bool, std::string> IsDowngradeJustified() const override { return {justified, justification}; }
    mip::AssignmentMethod GetNewLabelAssignmentMethod() const override { return method; }
    std::vector<mip::MetadataEntry> GetContentMetadata(const std::vector<std::string>& names,
                                                       const std::vector<std::string>& prefixes) const override {
        std::vector<mip::MetadataEntry> out;
        for (const auto& m : metadata) {
            bool hit = names.empty() && prefixes.empty();
            for (const auto& n : names) if (m.GetKey() == n) hit = true;
            for (const auto& p : prefixes) if (m.GetKey().compare(0, p.size(), p) == 0) hit = true;
            if (hit) out.push_back(m);
        }
        return out;
    }
    std::shared_ptr<mip::ProtectionDescriptor> GetProtectionDescriptor() const override { return nullptr; }
    std::string GetContentFormat() const override { return "email"; }
    mip::ActionType GetSupportedActions() const override {
        // Protection actions are declared so the SDK reports them (the app then refuses to send: no rpmsg writer).
        return mip::ActionType::METADATA | mip::ActionType::JUSTIFY | mip::ActionType::PROTECT_BY_TEMPLATE |
               mip::ActionType::PROTECT_DO_NOT_FORWARD | mip::ActionType::PROTECT_BY_ENCRYPT_ONLY |
               mip::ActionType::PROTECT_ADHOC | mip::ActionType::REMOVE_PROTECTION |
               mip::ActionType::ADD_CONTENT_HEADER | mip::ActionType::ADD_CONTENT_FOOTER | mip::ActionType::ADD_WATERMARK |
               mip::ActionType::REMOVE_CONTENT_HEADER | mip::ActionType::REMOVE_CONTENT_FOOTER | mip::ActionType::REMOVE_WATERMARK;
    }
};

bool has(mip::ActionType t, mip::ActionType bit) {
    return (static_cast<unsigned int>(t) & static_cast<unsigned int>(bit)) != 0;
}

} // namespace

extern "C" {

int nmb_abi_version(void) { return NMB_ABI_VERSION; }

const char* nmb_sdk_version(void) { return mip::FileProfile::GetVersion(); }

nmb_ctx* nmb_create(const char* client_id, const char* app_name, const char* app_version, const char* state_path,
                    const char* user_email, int protection_only, int cache_type, nmb_token_cb cb, void* user,
                    int timeout_sec, int* err, int* stage) {
    auto setErr = [&](int e, int s) { if (err) *err = e; if (stage) *stage = s; };
    setErr(NMB_OK, NMB_STAGE_NONE);
    if (cache_type != NMB_CACHE_IN_MEMORY && cache_type != NMB_CACHE_ON_DISK_ENCRYPTED) {
        setErr(NMB_ERR_BAD_ARG, NMB_STAGE_NONE);
        return nullptr;
    }
    const auto storage = cache_type == NMB_CACHE_ON_DISK_ENCRYPTED ? mip::CacheStorageType::OnDiskEncrypted
                                                                    : mip::CacheStorageType::InMemory;
    if (!client_id || !state_path || !user_email || !cb || !*client_id || !*user_email) {
        setErr(NMB_ERR_BAD_ARG, NMB_STAGE_NONE);
        return nullptr;
    }
    auto ctx = std::make_unique<nmb_ctx>();
    ctx->auth = std::make_shared<CallbackAuth>(cb, user);
    ctx->user = user_email;
    ctx->cacheType = cache_type;
    int st = NMB_STAGE_CONTEXT;
    try {
        mip::ApplicationInfo ai{client_id, app_name ? app_name : "niivo mail", app_version ? app_version : "0"};
        auto cfg = std::make_shared<mip::MipConfiguration>(ai, state_path, mip::LogLevel::Error,
                                                           /*isOfflineOnly*/ false, storage);
        cfg->SetLoggerDelegate(std::make_shared<NullLogger>());
        auto diag = std::make_shared<mip::DiagnosticConfiguration>();
        diag->isLocalCachingEnabled = false;     // no on-disk audit/telemetry queue
        diag->isMinimalTelemetryEnabled = true;  // only required service data
        cfg->SetDiagnosticConfiguration(diag);
        ctx->context = mip::MipContext::Create(cfg);

        st = NMB_STAGE_PROFILE;
        mip::FileProfile::Settings ps(ctx->context, storage,
                                      std::make_shared<RejectConsent>(), std::make_shared<ProfileObserver>());
        // BYOD (InMemory): no end-user licence cache at all. Managed + OnDiskEncrypted: cached for offline reading.
        ps.SetCanCacheLicenses(storage == mip::CacheStorageType::OnDiskEncrypted);
        auto pp = std::make_shared<Promise<mip::FileProfile>>();
        auto pf = pp->get_future();
        mip::FileProfile::LoadAsync(ps, pp);
        ctx->profile = await(pf, timeout_sec);

        st = NMB_STAGE_ENGINE;
        mip::FileEngine::Settings es(mip::Identity(user_email), ctx->auth, /*clientData*/ "", "en-US");
        es.SetProtectionOnlyEngine(protection_only != 0);
        es.SetCustomSettings({
            // MSG / rpmsg handling is behind a feature flag (learn.microsoft.com/information-protection/develop/concept-email).
            {"enable_msg_file_type", "true"},
            {mip::GetCustomSettingContainerDecryptionOption(),
             mip::ContainerDecryptionOptionString(mip::ContainerDecryptionOption::Top)},
        });
        auto ep = std::make_shared<Promise<mip::FileEngine>>();
        auto ef = ep->get_future();
        ctx->profile->AddEngineAsync(es, ep);
        ctx->engine = await(ef, timeout_sec);
        return ctx.release();
    } catch (...) {
        setErr(classify(std::current_exception(), ctx->auth.get()), st);
        ctx->engine.reset();
        ctx->profile.reset();
        if (ctx->context) { try { ctx->context->ShutDown(); } catch (...) {} }
        return nullptr;
    }
}

int nmb_inspect_rpmsg(nmb_ctx* ctx, const uint8_t* data, size_t len, int timeout_sec, nmb_result* out) {
    if (!out) return NMB_ERR_BAD_ARG;
    std::memset(out, 0, sizeof(*out));
    if (!ctx || !ctx->engine || !data || len == 0) return NMB_ERR_BAD_ARG;
    ctx->auth->reset();
    int st = NMB_STAGE_HANDLER;
    // The stream must outlive the handler, so the operation owns its copy of the bytes.
    auto bytes = std::make_shared<std::vector<uint8_t>>(data, data + len);
    if (std::getenv("NIIVO_MIP_DIAG")) {   // format signature only (first 8 bytes), never content
        std::fprintf(stderr, "[MIPDIAG] input len=%zu magic=", len);
        for (size_t i = 0; i < len && i < 8; ++i) std::fprintf(stderr, "%02x", data[i]);
        std::fprintf(stderr, "\n");
    }
    try {
        auto stream = mip::CreateStreamFromBuffer(bytes->data(), static_cast<int64_t>(bytes->size()));
        auto obs = std::make_shared<HandlerObserver>();
        auto hp = std::make_shared<Promise<mip::FileHandler>>();
        auto hf = hp->get_future();
        // The name is only used for format detection / audit; ".rpmsg" routes it to the MSG inspector.
        // Audit discovery off: we don't want our app to emit per-item AipDiscover events in this spike.
        ctx->engine->CreateFileHandlerAsync(stream, "message.rpmsg", /*isAuditDiscoveryEnabled*/ false, obs, hp,
                                            nullptr, /*isGetSensitivityLabelAuditDiscoveryEnabled*/ false);
        auto handler = await(hf, timeout_sec);

        st = NMB_STAGE_INSPECT;
        auto ip = std::make_shared<Promise<mip::FileInspector>>();
        auto ifu = ip->get_future();
        handler->InspectAsync(ip);
        auto inspector = await(ifu, timeout_sec);
        auto msg = std::dynamic_pointer_cast<mip::MsgInspector>(inspector);
        out->auth_calls = ctx->auth->calls();
        if (!msg || inspector->GetInspectorType() != mip::InspectorType::Msg) {
            out->stage = st; zero(*bytes); return NMB_ERR_NOT_MSG;
        }

        // Rights + owner from the licence, when the handler exposes it.
        std::string rights, owner;
        int source = NMB_RIGHTS_NONE;
        try {
            if (auto prot = handler->GetProtection()) {
                for (const auto& r : prot->GetRights()) { if (!rights.empty()) rights += ","; rights += r; }
                owner = prot->GetOwner();
                source = NMB_RIGHTS_PROTECTION_HANDLER;
            }
        } catch (...) { source = NMB_RIGHTS_NONE; rights.clear(); owner.clear(); }

        st = NMB_STAGE_BODY;
        const auto& body = msg->GetBody();
        int bt;
        switch (msg->GetBodyType()) {
            case mip::BodyType::HTML: bt = NMB_BODY_HTML; break;
            case mip::BodyType::TXT: bt = NMB_BODY_TEXT; break;
            case mip::BodyType::RTF: bt = NMB_BODY_RTF; break;
            default: bt = NMB_BODY_UNKNOWN; break;
        }
        out->body_type = bt;
        out->rights = dupstr(rights);
        out->rights_source = source;
        out->owner = dupstr(owner);
        // RTF is returned as-is (often compressed / HTML-encapsulated); the Swift side converts it in memory.
        if (bt != NMB_BODY_HTML && bt != NMB_BODY_TEXT && bt != NMB_BODY_RTF) {
            out->stage = st; zero(*bytes); return NMB_ERR_UNSUPPORTED_BODY;
        }
        out->body = static_cast<uint8_t*>(std::malloc(body.size() ? body.size() : 1));
        if (!out->body) { zero(*bytes); return NMB_ERR_INTERNAL; }
        if (!body.empty()) std::memcpy(out->body, body.data(), body.size());
        out->body_len = body.size();
        zero(*bytes);
        return NMB_OK;
    } catch (...) {
        out->stage = st;
        out->auth_calls = ctx->auth->calls();
        zero(*bytes);
        return classify(std::current_exception(), ctx->auth.get());
    }
}

void nmb_result_free(nmb_result* r) {
    if (!r) return;
    if (r->body) { std::memset(r->body, 0, r->body_len); std::free(r->body); }
    if (r->rights) std::free(r->rights);
    if (r->owner) { std::memset(r->owner, 0, std::strlen(r->owner)); std::free(r->owner); }
    std::memset(r, 0, sizeof(*r));
}

// ---- ABI 1 additions (optional symbols; Swift resolves them with dlsym and falls back without them) ------------

int nmb_policy_load(nmb_ctx* ctx, int timeout_sec, nmb_policy* out) {
    if (!out) return NMB_ERR_BAD_ARG;
    std::memset(out, 0, sizeof(*out));
    if (!ctx || !ctx->context) return NMB_ERR_BAD_ARG;
    ctx->auth->reset();
    out->stage = NMB_STAGE_POLICY;
    try {
        ensurePolicyEngine(ctx, timeout_sec);
        auto& pe = ctx->policyEngine;
        // Outlook labels meetings with the "email" content format too (the SDK headers name no meeting format).
        auto def = pe->GetDefaultSensitivityLabel("email");
        out->default_mail_label = dupstr(def ? def->GetId() : "");
        out->mail_mandatory = pe->IsLabelingRequired("email") ? 1 : 0;
        out->justification_required = pe->IsDowngradeJustificationRequired() ? 1 : 0;
        out->tenant_id = dupstr(pe->GetTenantId());
        // Protection kind per label: 0 none, 1 template, 2 do-not-forward, 3 encrypt-only, 4 adhoc.
        std::string kinds;
        std::vector<std::shared_ptr<mip::Label>> stack;
        for (const auto& l : pe->ListSensitivityLabels({"email"})) stack.push_back(l);
        while (!stack.empty()) {
            auto l = stack.back(); stack.pop_back();
            if (!l) continue;
            int k = 0;
            if (l->HasDoNotForwardProtection()) k = 2;
            else if (l->HasEncryptOnlyProtection()) k = 3;
            else if (l->HasAdhocProtection()) k = 4;
            else if (l->HasRightsManagementPolicy()) k = 1;
            kinds += l->GetId() + "\t" + std::to_string(k) + "\n";
            for (const auto& c : l->GetChildren()) stack.push_back(c);
        }
        out->label_protection = dupstr(kinds);
        out->auth_calls = ctx->auth->calls();
        out->stage = 0;
        return NMB_OK;
    } catch (...) {
        out->auth_calls = ctx->auth->calls();
        return classify(std::current_exception(), ctx->auth.get());
    }
}

void nmb_policy_free(nmb_policy* p) {
    if (!p) return;
    std::free(p->default_mail_label); std::free(p->tenant_id); std::free(p->label_protection);
    std::memset(p, 0, sizeof(*p));
}

int nmb_label_compute(nmb_ctx* ctx, const char* new_label_id, const char* existing_metadata, int privileged,
                      const char* justification, const char* content_id, int commit, int timeout_sec,
                      nmb_label_plan* out) {
    if (!out) return NMB_ERR_BAD_ARG;
    std::memset(out, 0, sizeof(*out));
    if (!ctx || !ctx->context) return NMB_ERR_BAD_ARG;
    ctx->auth->reset();
    out->stage = NMB_STAGE_POLICY;
    try {
        ensurePolicyEngine(ctx, timeout_sec);
        out->stage = NMB_STAGE_LABEL;
        EmailState st;
        if (new_label_id && *new_label_id) {
            st.label = ctx->policyEngine->GetLabelById(new_label_id);
            if (!st.label) { out->auth_calls = ctx->auth->calls(); return NMB_ERR_BAD_INPUT; }
        }
        st.metadata = parseMetadata(existing_metadata);
        st.method = privileged ? mip::AssignmentMethod::PRIVILEGED : mip::AssignmentMethod::STANDARD;
        st.contentId = content_id ? content_id : "";
        if (justification && *justification) { st.justified = true; st.justification = justification; }
        // Audit discovery stays off; NotifyCommittedActions is the documented audit hook for the label change.
        auto handler = ctx->policyEngine->CreatePolicyHandler(/*isAuditDiscoveryEnabled*/ false, false);
        std::string add, remove;
        for (const auto& a : handler->ComputeActions(st)) {
            if (!a) continue;
            const auto t = a->GetType();
            if (has(t, mip::ActionType::JUSTIFY)) out->needs_justification = 1;
            if (has(t, mip::ActionType::PROTECT_BY_TEMPLATE) || has(t, mip::ActionType::PROTECT_ADHOC) ||
                has(t, mip::ActionType::PROTECT_DO_NOT_FORWARD) || has(t, mip::ActionType::PROTECT_BY_ENCRYPT_ONLY) ||
                has(t, mip::ActionType::PROTECT_ADHOC_DK) || has(t, mip::ActionType::PROTECT_DO_NOT_FORWARD_DK))
                out->applies_protection = 1;
            if (has(t, mip::ActionType::METADATA)) {
                if (auto m = std::dynamic_pointer_cast<mip::MetadataAction>(a)) {
                    for (const auto& k : m->GetMetadataToRemove()) remove += k + "\n";
                    for (const auto& e : m->GetMetadataToAdd()) add += e.GetKey() + "=" + e.GetValue() + "\n";
                }
            }
        }
        out->metadata_add = dupstr(add);
        out->metadata_remove = dupstr(remove);
        if (commit && !out->needs_justification && !out->applies_protection) {
            out->stage = NMB_STAGE_COMMIT;
            // The committed state is the old metadata minus removals plus additions.
            std::vector<mip::MetadataEntry> committed;
            for (const auto& e : st.metadata)
                if (remove.find(e.GetKey() + "\n") == std::string::npos) committed.push_back(e);
            for (const auto& e : parseMetadata(out->metadata_add)) committed.push_back(e);
            st.metadata = committed;
            handler->NotifyCommittedActions(st);
            out->committed = 1;
        }
        out->auth_calls = ctx->auth->calls();
        out->stage = 0;
        return NMB_OK;
    } catch (...) {
        out->auth_calls = ctx->auth->calls();
        return classify(std::current_exception(), ctx->auth.get());
    }
}

void nmb_label_plan_free(nmb_label_plan* p) {
    if (!p) return;
    std::free(p->metadata_add); std::free(p->metadata_remove);
    std::memset(p, 0, sizeof(*p));
}

int nmb_inspect_rpmsg_attachments(nmb_ctx* ctx, const uint8_t* data, size_t len, int timeout_sec, nmb_attachments* out) {
    if (!out) return NMB_ERR_BAD_ARG;
    std::memset(out, 0, sizeof(*out));
    if (!ctx || !ctx->engine || !data || len == 0) return NMB_ERR_BAD_ARG;
    ctx->auth->reset();
    int st = NMB_STAGE_HANDLER;
    auto bytes = std::make_shared<std::vector<uint8_t>>(data, data + len);
    try {
        auto stream = mip::CreateStreamFromBuffer(bytes->data(), static_cast<int64_t>(bytes->size()));
        auto obs = std::make_shared<HandlerObserver>();
        auto hp = std::make_shared<Promise<mip::FileHandler>>();
        auto hf = hp->get_future();
        ctx->engine->CreateFileHandlerAsync(stream, "message.rpmsg", false, obs, hp, nullptr, false);
        auto handler = await(hf, timeout_sec);
        st = NMB_STAGE_INSPECT;
        auto ip = std::make_shared<Promise<mip::FileInspector>>();
        auto ifu = ip->get_future();
        handler->InspectAsync(ip);
        auto inspector = await(ifu, timeout_sec);
        auto msg = std::dynamic_pointer_cast<mip::MsgInspector>(inspector);
        out->auth_calls = ctx->auth->calls();
        if (!msg) { out->stage = st; zero(*bytes); return NMB_ERR_NOT_MSG; }
        std::string rights;
        int source = NMB_RIGHTS_NONE;
        try {
            if (auto prot = handler->GetProtection()) {
                for (const auto& r : prot->GetRights()) { if (!rights.empty()) rights += ","; rights += r; }
                source = NMB_RIGHTS_PROTECTION_HANDLER;
            }
        } catch (...) { source = NMB_RIGHTS_NONE; rights.clear(); }
        out->rights = dupstr(rights);
        out->rights_source = source;
        st = NMB_STAGE_ATTACHMENTS;
        // GetBytes() only: never GetStream()/temporary files. The engine keeps container option Top, so an
        // attachment that is itself protected comes back still protected (the reader says so).
        const auto& atts = msg->GetAttachments();
        if (!atts.empty()) {
            out->items = static_cast<nmb_attachment*>(std::calloc(atts.size(), sizeof(nmb_attachment)));
            if (!out->items) { zero(*bytes); return NMB_ERR_INTERNAL; }
        }
        for (const auto& a : atts) {
            if (!a) continue;
            auto& slot = out->items[out->count];
            const std::string& name = a->GetLongName().empty() ? a->GetName() : a->GetLongName();
            slot.name = dupstr(name);
            slot.content_id = dupstr(a->GetContentId());
            const auto& b = a->GetBytes();
            slot.data = static_cast<uint8_t*>(std::malloc(b.size() ? b.size() : 1));
            if (!slot.data) { zero(*bytes); return NMB_ERR_INTERNAL; }
            if (!b.empty()) std::memcpy(slot.data, b.data(), b.size());
            slot.len = b.size();
            out->count += 1;
        }
        out->stage = 0;
        zero(*bytes);
        return NMB_OK;
    } catch (...) {
        out->stage = st;
        out->auth_calls = ctx->auth->calls();
        zero(*bytes);
        return classify(std::current_exception(), ctx->auth.get());
    }
}

void nmb_attachments_free(nmb_attachments* a) {
    if (!a) return;
    for (size_t i = 0; i < a->count; ++i) {
        auto& s = a->items[i];
        if (s.data) { std::memset(s.data, 0, s.len); std::free(s.data); }
        if (s.name) { std::memset(s.name, 0, std::strlen(s.name)); std::free(s.name); }
        std::free(s.content_id);
    }
    std::free(a->items);
    std::free(a->rights);
    std::memset(a, 0, sizeof(*a));
}

void nmb_destroy(nmb_ctx* ctx) {
    if (!ctx) return;
    ctx->policyEngine.reset();
    ctx->policyProfile.reset();
    ctx->engine.reset();
    ctx->profile.reset();
    if (ctx->context) { try { ctx->context->ShutDown(); } catch (...) {} }
    delete ctx;
}

} // extern "C"
