#define main scansnap_wifi_program_main
#include "scansnap.c"
#undef main

static void require_true(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

int main(void) {
    uint8_t response[64] = {0};
    static const uint8_t feeder_empty_tail[12] = {
        0x00, 0x0a, 0x00, 0x00, 0x00, 0x00,
        0x80, 0x03, 0x00, 0x00, 0x00, 0x00,
    };

    require_true(!scan_response_reports_feeder_empty(response, sizeof(response)),
                 "an all-zero status must not report an empty feeder");

    response[sizeof(response) - 1] = 1;
    require_true(!scan_response_reports_feeder_empty(response, sizeof(response)),
                 "an unrelated non-zero status byte must not end a scan");

    memset(response, 0, sizeof(response));
    memcpy(response + sizeof(response) - sizeof(feeder_empty_tail),
           feeder_empty_tail, sizeof(feeder_empty_tail));
    require_true(scan_response_reports_feeder_empty(response, sizeof(response)),
                 "the captured iX500 terminal status must report an empty feeder");

    response[sizeof(response) - 1] = 1;
    require_true(!scan_response_reports_feeder_empty(response, sizeof(response)),
                 "the feeder-empty status must match exactly");

    memset(response, 0, sizeof(response));
    memcpy(response + 4, "VENS", 4);
    int32_t error_code = 123;
    require_true(!scan_response_is_error(response, sizeof(response), &error_code),
                 "a zero VENS status must not be treated as an error");

    put_be32(response + 8, (uint32_t)-7);
    require_true(scan_response_is_error(response, sizeof(response), &error_code),
                 "a non-zero VENS status must be treated as an error");
    require_true(error_code == -7, "the signed VENS status must be preserved");

    memcpy(response + 4, "NOPE", 4);
    require_true(!scan_response_is_error(response, sizeof(response), &error_code),
                 "non-VENS image data must not be treated as an error response");
    require_true(!scan_response_is_error(response, 11, &error_code),
                 "a short response must not be parsed as VENS");

    puts("ScanSnap response tests passed");
    return 0;
}
