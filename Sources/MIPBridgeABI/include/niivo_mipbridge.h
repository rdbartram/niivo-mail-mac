// niivo MIP bridge: a tiny pure-C ABI over the Microsoft Information Protection (MIP) File SDK (C++).
//
// Single source of truth for the ABI: this header (SwiftPM C target MIPBridgeABI, types only, no linking).
// The implementation (native/mipbridge/niivo_mipbridge.cpp) is built OUTSIDE SwiftPM by scripts/build-mipbridge.sh into vendor/mip/lib/libniivo_mipbridge.dylib and loaded at
// runtime with dlopen (Sources/ProtectedContent/MIPLoader.swift). No existing product links the SDK, so the app,
// OfficeMCP and CoreSelfTest build and run unchanged whether or not vendor/mip exists. See docs/MIP.md.
//
// Rules this ABI enforces:
//  * licence/policy caches are in memory only (mip::CacheStorageType::InMemory on MipConfiguration AND the profile,
//    licence caching off), the SDK logger is a no-op, telemetry local caching is off;
//  * the decrypted body is only ever returned in a heap buffer owned by the caller (nmb_result_free zeroes it);
//    the bridge never calls GetDecryptedTemporaryFile*/Stream* and never writes plaintext anywhere;
//  * errors are reported as codes plus a stage, never as exception text (MIP messages can embed addresses).
#ifndef NIIVO_MIPBRIDGE_H
#define NIIVO_MIPBRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NMB_ABI_VERSION 1
#define NMB_API __attribute__((visibility("default")))

/// Result codes. Keep in sync with `MIPBridgeError` in Sources/ProtectedContent/MIPLoader.swift.
enum {
    NMB_OK = 0,
    NMB_ERR_BAD_ARG = 1,
    NMB_ERR_AUTH = 2,              // token callback failed or returned nothing
    NMB_ERR_CLAIMS_CHALLENGE = 3,  // RMS asked for extra claims (CA / label-based CA); caller must re-auth interactively
    NMB_ERR_NO_PERMISSION = 4,     // user has no rights on this content (or it was revoked / expired)
    NMB_ERR_ACCESS_DENIED = 5,     // user can't use the RMS service at all (licence, disabled service)
    NMB_ERR_BAD_INPUT = 6,         // not an rpmsg / corrupt / unsupported format
    NMB_ERR_NETWORK = 7,
    NMB_ERR_TIMEOUT = 8,
    NMB_ERR_NOT_MSG = 9,           // inspection didn't yield an MsgInspector
    NMB_ERR_UNSUPPORTED_BODY = 10, // RTF or unknown body type
    NMB_ERR_CONSENT = 11,
    NMB_ERR_INTERNAL = 12,
};

/// Stage at which an error happened (for diagnostics without content).
enum { NMB_STAGE_NONE = 0, NMB_STAGE_CONTEXT = 1, NMB_STAGE_PROFILE = 2, NMB_STAGE_ENGINE = 3,
       NMB_STAGE_HANDLER = 4, NMB_STAGE_INSPECT = 5, NMB_STAGE_BODY = 6,
       // ABI 1 additions (Purview label policy / attachments)
       NMB_STAGE_POLICY = 7, NMB_STAGE_LABEL = 8, NMB_STAGE_COMMIT = 9, NMB_STAGE_ATTACHMENTS = 10 };

/// Where the rights came from.
enum { NMB_RIGHTS_NONE = 0,              // no licence object exposed; caller knows only that VIEW succeeded
       NMB_RIGHTS_PROTECTION_HANDLER = 1 // FileHandler::GetProtection()->GetRights()
};

/// Mirrors mip::CacheStorageType values (InMemory = 0, OnDiskEncrypted = 2); plaintext OnDisk is never offered.
enum { NMB_CACHE_IN_MEMORY = 0, NMB_CACHE_ON_DISK_ENCRYPTED = 2 };

enum { NMB_BODY_UNKNOWN = 0, NMB_BODY_TEXT = 1, NMB_BODY_HTML = 2, NMB_BODY_RTF = 3 };

/// Token callback, called synchronously on an SDK thread. `resource` is e.g. https://aadrm.com or
/// https://syncservice.o365syncservice.com, `scope` may be empty, `claims` non-empty means a claims challenge.
/// Write a NUL-terminated access token into `out` (capacity `cap`). Return NMB_OK, NMB_ERR_AUTH or
/// NMB_ERR_CLAIMS_CHALLENGE.
typedef int (*nmb_token_cb)(void* user, const char* authority, const char* resource, const char* scope,
                            const char* claims, char* out, size_t cap);

typedef struct nmb_ctx nmb_ctx;

typedef struct {
    uint8_t* body;        // UTF-8 (HTML or text); caller frees with nmb_result_free (zeroed first)
    size_t body_len;
    int body_type;        // NMB_BODY_*
    char* rights;         // comma-separated RMS rights (VIEW,EXTRACT,...), may be empty
    int rights_source;    // NMB_RIGHTS_*
    char* owner;          // licence owner (an address) or empty; never log it
    int stage;            // NMB_STAGE_* where it failed (0 on success)
    int auth_calls;       // how many times the token callback ran (diagnostic)
} nmb_result;

NMB_API int nmb_abi_version(void);
/// "1.18.148" etc. Static storage.
NMB_API const char* nmb_sdk_version(void);

/// Creates MipContext + FileProfile (InMemory) + FileEngine for `user_email`.
/// `state_path` must be an existing, empty, private directory; the SDK requires a path even for InMemory.
/// `cache_type`: NMB_CACHE_IN_MEMORY (BYOD default: nothing persisted, licence caching off) or
/// NMB_CACHE_ON_DISK_ENCRYPTED (managed Macs only, when policy allows: SQLite cache encrypted with OS key APIs,
/// licence caching on; `state_path` must then be a persistent private directory).
/// `protection_only` = 1 adds a protection-only engine (no policy sync, so only the RMS token is needed).
NMB_API nmb_ctx* nmb_create(const char* client_id, const char* app_name, const char* app_version, const char* state_path,
                    const char* user_email, int protection_only, int cache_type, nmb_token_cb cb, void* user,
                    int timeout_sec, int* err, int* stage);

/// Decrypts a message.rpmsg (or message_v2/v3/v4.rpmsg) for display. Bytes are copied; the input can be freed after.
NMB_API int nmb_inspect_rpmsg(nmb_ctx* ctx, const uint8_t* data, size_t len, int timeout_sec, nmb_result* out);

NMB_API void nmb_result_free(nmb_result* r);

// ---- Additions within ABI 1 -------------------------------------------------------------------------------------
// New symbols only; the existing functions and nmb_result are unchanged. The Swift side resolves these with dlsym
// and treats a missing symbol as "no MIP policy" (Graph label list, no default / mandatory / justification).

/// Label policy for the signed-in user (Policy SDK engine; needs the policy-sync token
/// https://syncservice.o365syncservice.com UnifiedPolicy.User.Read through the same token callback).
typedef struct {
    char* default_mail_label;   // label GUID or "" (content format "email"; also used for meetings)
    int mail_mandatory;         // IsLabelingRequired("email")
    int justification_required; // IsDowngradeJustificationRequired()
    char* tenant_id;            // the policy's tenant (SiteId in msip_labels)
    char* label_protection;     // "id\tkind\n" lines; kind 0 none, 1 template, 2 do-not-forward, 3 encrypt-only, 4 adhoc
    int stage;
    int auth_calls;
} nmb_policy;

NMB_API int nmb_policy_load(nmb_ctx* ctx, int timeout_sec, nmb_policy* out);
NMB_API void nmb_policy_free(nmb_policy* p);

/// What applying a label to an outgoing mail / meeting means (PolicyHandler::ComputeActions on an "email" state).
typedef struct {
    char* metadata_add;      // "key=value\n" lines (MSIP_Label_<guid>_*), joined with "; " into msip_labels
    char* metadata_remove;   // "key\n" lines
    int needs_justification; // a JustifyAction came back: ask the user, call again with the text
    int applies_protection;  // the label encrypts (the app refuses to send: no Outlook-compatible rpmsg writer)
    int committed;           // NotifyCommittedActions ran (audit event incl. justification)
    int stage;
    int auth_calls;
} nmb_label_plan;

/// `existing_metadata`: the item's current msip_labels as "key=value\n" lines (may be empty). `new_label_id` empty =
/// remove the label. `privileged` = the user picked it (Method=Privileged) vs default (Standard). `justification`
/// non-empty = the downgrade is justified with this text. `commit` = also call NotifyCommittedActions (only when no
/// justification is outstanding and nothing needs protection). `content_id` is the audit's content description.
NMB_API int nmb_label_compute(nmb_ctx* ctx, const char* new_label_id, const char* existing_metadata, int privileged,
                              const char* justification, const char* content_id, int commit, int timeout_sec,
                              nmb_label_plan* out);
NMB_API void nmb_label_plan_free(nmb_label_plan* p);

typedef struct {
    char* name;        // file name (long name when present); never log it
    char* content_id;  // inline image cid or ""
    uint8_t* data;     // plaintext bytes, zeroed on free
    size_t len;
} nmb_attachment;

typedef struct {
    nmb_attachment* items;
    size_t count;
    char* rights;      // same as nmb_result.rights
    int rights_source;
    int stage;
    int auth_calls;
} nmb_attachments;

/// Second pass over a message.rpmsg: its attachments (MsgInspector::GetAttachments, bytes only, in memory).
NMB_API int nmb_inspect_rpmsg_attachments(nmb_ctx* ctx, const uint8_t* data, size_t len, int timeout_sec,
                                          nmb_attachments* out);
NMB_API void nmb_attachments_free(nmb_attachments* a);

/// Shuts the MipContext down and frees everything.
NMB_API void nmb_destroy(nmb_ctx* ctx);

#ifdef __cplusplus
}
#endif
#endif
