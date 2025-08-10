#include <signal.h>

// Provide globals expected by Trealla when embedded
char **g_envp = 0;

// Provide the SIGINT handler symbol referenced by toplevel.c
void sigfn(int s)
{
    (void)s;
}

// Provide empty builtins tables expected when NOFFI/NOTHREADS
typedef struct builtins_
{
    const char *name;
    unsigned arity;
    void *fn;
    const char *help;
    int evaluable;
    int ffi;
    unsigned char types[32];
    unsigned char ret_type;
    const char *ret_name;
} builtins;

builtins g_ffi_bifs[1] = {{0}};
