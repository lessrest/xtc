// Minimal embedded library shim for Trealla
// We provide an empty g_libs[] to satisfy references in prolog/module code
// when building a minimal engine without bundled Prolog libraries.

#include "library.h"

library g_libs[] = {
    {0}};
