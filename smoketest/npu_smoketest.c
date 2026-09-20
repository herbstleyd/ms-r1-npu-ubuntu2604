#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "cix_noe_standard_api.h"

int main(void) {
    context_handler_t *ctx = NULL;
    noe_status_t st = noe_init_context(&ctx);
    if (st != NOE_STATUS_SUCCESS) {
        printf("noe_init_context failed: 0x%x\n", st);
        return 1;
    }
    printf("noe_init_context OK ctx=%p (handle=%u)\n", (void*)ctx, ctx ? ctx->handle : 0);

    char target[128] = {0};
    if (noe_get_target(ctx, target) == NOE_STATUS_SUCCESS) {
        printf("target: %s\n", target);
    }

    uint32_t parts = 0;
    if (noe_get_partition_count(ctx, &parts) == NOE_STATUS_SUCCESS) {
        printf("partition_count: %u\n", parts);
        for (uint32_t p = 0; p < parts; ++p) {
            uint32_t clusters = 0;
            noe_get_cluster_count(ctx, p, &clusters);
            printf("  partition %u: %u clusters\n", p, clusters);
            for (uint32_t c = 0; c < clusters; ++c) {
                uint32_t cores = 0;
                noe_get_core_count(ctx, p, c, &cores);
                printf("    cluster %u: %u cores\n", c, cores);
            }
        }
    }

    noe_deinit_context(ctx);
    printf("OK\n");
    return 0;
}
