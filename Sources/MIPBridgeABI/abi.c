// Header-only C target: exposes the exact nmb_* ABI types (structs, enums, function-pointer shapes) to Swift.
// Nothing here links the MIP SDK; ProtectedContent resolves the functions with dlsym at runtime (docs/MIP.md).
#include "niivo_mipbridge.h"
