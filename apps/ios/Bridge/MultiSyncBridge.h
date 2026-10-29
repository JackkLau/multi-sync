#ifndef MULTISYNC_BRIDGE_H
#define MULTISYNC_BRIDGE_H
char *multisync_call(const char *request_json);
void multisync_free(char *response_json);
#endif
