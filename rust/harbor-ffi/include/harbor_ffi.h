#ifndef HARBOR_FFI_H
#define HARBOR_FFI_H

char *harbor_core_version(void);
char *harbor_run_pipeline(const char *streams_json, const char *trust_json, const char *score_json);
void harbor_string_free(char *p);

#endif
