#define main scansnap_wifi_program_main
#include "scansnap.c"
#undef main

static void require_true(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void test_dynamic_simplex_collection(void) {
    struct page *pages = NULL;
    size_t count = 0;
    size_t capacity = 0;
    size_t side_number = 0;

    for (int batch_number = 0; batch_number < 3; batch_number++) {
        struct page batch[MAX_PAGES] = {0};
        int batch_count = batch_number < 2 ? MAX_PAGES : 88;
        for (int index = 0; index < batch_count; index++) {
            batch[index].data = malloc(1);
            require_true(batch[index].data != NULL, "test page allocation must succeed");
            batch[index].len = side_number + 1;
            side_number++;
        }

        require_true(
            append_batch_pages(
                &pages, &count, &capacity, batch, batch_count, true
            ) == 0,
            "simplex pages must append across dynamic transfer batches"
        );
        for (int index = 0; index < batch_count; index++) {
            require_true(batch[index].data == NULL,
                         "the dynamic collector must take or release every batch side");
        }
    }

    require_true(count == 300,
                 "600 transferred sides must yield 300 simplex pages without a 128-page cap");
    require_true(capacity >= count,
                 "the dynamic page array must grow beyond one protocol batch");
    for (size_t index = 0; index < count; index++) {
        require_true(pages[index].len == index * 2 + 1,
                     "simplex fronts must remain in scanner order");
    }
    free_pages(pages, count);
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

    test_dynamic_simplex_collection();

    puts("ScanSnap response tests passed");
    return 0;
}
