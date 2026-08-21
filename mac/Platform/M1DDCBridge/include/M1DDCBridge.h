#ifndef M1DDC_BRIDGE_H
#define M1DDC_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

int32_t ds_ddc_set_philips_input(
    uint16_t input_value,
    char *error_buffer,
    size_t error_buffer_size
);

#endif
