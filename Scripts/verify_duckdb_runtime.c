#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef const char *(*duckdb_library_version_function)(void);

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: verify_duckdb_runtime /path/to/libduckdb.dylib expected-version\n");
        return 64;
    }
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "Could not load DuckDB: %s\n", dlerror());
        return 65;
    }
    duckdb_library_version_function version_function =
        (duckdb_library_version_function)dlsym(handle, "duckdb_library_version");
    if (version_function == NULL) {
        fprintf(stderr, "DuckDB has no duckdb_library_version symbol.\n");
        dlclose(handle);
        return 65;
    }
    const char *actual_version = version_function();
    if (actual_version == NULL || strcmp(actual_version, argv[2]) != 0) {
        fprintf(stderr, "Expected DuckDB %s, found %s.\n", argv[2],
                actual_version == NULL ? "(null)" : actual_version);
        dlclose(handle);
        return 65;
    }
    puts(actual_version);
    dlclose(handle);
    return 0;
}
