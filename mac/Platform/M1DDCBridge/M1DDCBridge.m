/*
 Derived from waydabber/m1ddc.

 MIT License

 Copyright (c) 2021 waydabber

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <mach/error.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#include "M1DDCBridge.h"

typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreateWithService(
    CFAllocatorRef allocator,
    io_service_t service
);
extern IOReturn IOAVServiceWriteI2C(
    IOAVServiceRef service,
    uint32_t chip_address,
    uint32_t data_address,
    void *input_buffer,
    uint32_t input_buffer_size
);
typedef CFDictionaryRef (*CreateDisplayInfoFunction)(CGDirectDisplayID display_id);

static const uint32_t kPhilipsVendor = 16652;
static const uint32_t kPhilipsModel = 49775;
static const uint32_t kPhilipsSerial = 85;
static const uint32_t kDefaultChipAddress = 0x37;
static const uint32_t kMCDP29XXChipAddress = 0xB7;
static const uint32_t kInputDataAddress = 0x51;
static const uint8_t kInputVCPCode = 0x60;

static void SetError(char *buffer, size_t size, NSString *message) {
    if (buffer == NULL || size == 0) {
        return;
    }
    snprintf(buffer, size, "%s", message.UTF8String ?: "Unknown DDC error");
}

static CreateDisplayInfoFunction ResolveCreateDisplayInfoFunction(void **framework_handle) {
    *framework_handle = dlopen(
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        RTLD_LAZY | RTLD_LOCAL
    );
    if (*framework_handle == NULL) {
        return NULL;
    }
    return (CreateDisplayInfoFunction)dlsym(
        *framework_handle,
        "CoreDisplay_DisplayCreateInfoDictionary"
    );
}

static CFTypeRef CopyRecursiveProperty(io_service_t service, CFStringRef key) {
    return IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        key,
        kCFAllocatorDefault,
        kIORegistryIterateRecursively
    );
}

static Boolean StringPropertyEquals(CFTypeRef value, CFStringRef expected) {
    return value != NULL
        && CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringCompare((CFStringRef)value, expected, 0) == kCFCompareEqualTo;
}

static io_service_t CopyPhilipsAdapter(
    CreateDisplayInfoFunction create_display_info,
    char *error_buffer,
    size_t error_buffer_size
) {
    CGDisplayCount count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        SetError(error_buffer, error_buffer_size, @"Could not enumerate online displays");
        return MACH_PORT_NULL;
    }

    CGDirectDisplayID *display_ids = calloc(count, sizeof(CGDirectDisplayID));
    if (display_ids == NULL) {
        SetError(error_buffer, error_buffer_size, @"Could not allocate display list");
        return MACH_PORT_NULL;
    }
    CGDisplayCount actual_count = 0;
    CGError list_error = CGGetOnlineDisplayList(count, display_ids, &actual_count);
    if (list_error != kCGErrorSuccess || actual_count > count) {
        free(display_ids);
        SetError(error_buffer, error_buffer_size, @"Could not read online display list");
        return MACH_PORT_NULL;
    }

    io_service_t matched_adapter = MACH_PORT_NULL;
    int matched_count = 0;
    for (CGDisplayCount index = 0; index < actual_count; ++index) {
        CGDirectDisplayID display_id = display_ids[index];
        if (CGDisplayVendorNumber(display_id) != kPhilipsVendor
            || CGDisplayModelNumber(display_id) != kPhilipsModel
            || CGDisplaySerialNumber(display_id) != kPhilipsSerial) {
            continue;
        }

        CFDictionaryRef info = create_display_info(display_id);
        if (info == NULL) {
            continue;
        }
        CFTypeRef uuid = CFDictionaryGetValue(info, CFSTR("kCGDisplayUUID"));
        CFTypeRef location = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
        Boolean stable_uuid_matches = StringPropertyEquals(
            uuid,
            CFSTR("45385DB6-3299-4343-A086-2392289D621A")
        );
        if (!stable_uuid_matches || location == NULL
            || CFGetTypeID(location) != CFStringGetTypeID()) {
            CFRelease(info);
            continue;
        }

        io_service_t adapter = IORegistryEntryCopyFromPath(
            kIOMainPortDefault,
            (CFStringRef)location
        );
        CFRelease(info);
        if (adapter == MACH_PORT_NULL) {
            continue;
        }

        CFTypeRef edid_uuid = CopyRecursiveProperty(adapter, CFSTR("EDID UUID"));
        Boolean edid_matches = StringPropertyEquals(
            edid_uuid,
            CFSTR("410C6FC2-0000-0000-1420-0103803C2278")
        );
        if (edid_uuid != NULL) {
            CFRelease(edid_uuid);
        }
        if (!edid_matches) {
            IOObjectRelease(adapter);
            continue;
        }

        matched_count += 1;
        if (matched_adapter != MACH_PORT_NULL) {
            IOObjectRelease(matched_adapter);
        }
        matched_adapter = adapter;
    }
    free(display_ids);

    if (matched_count != 1) {
        if (matched_adapter != MACH_PORT_NULL) {
            IOObjectRelease(matched_adapter);
        }
        SetError(
            error_buffer,
            error_buffer_size,
            [NSString stringWithFormat:@"Expected one Philips display, found %d", matched_count]
        );
        return MACH_PORT_NULL;
    }
    return matched_adapter;
}

static Boolean IsMCDP29XXProxy(io_service_t proxy) {
    io_registry_entry_t parent = MACH_PORT_NULL;
    if (IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) != KERN_SUCCESS) {
        return false;
    }
    CFTypeRef provider_class = IORegistryEntryCreateCFProperty(
        parent,
        CFSTR("EPICProviderClass"),
        kCFAllocatorDefault,
        0
    );
    Boolean matches = StringPropertyEquals(provider_class, CFSTR("AppleDCPMCDP29XX"));
    if (provider_class != NULL) {
        CFRelease(provider_class);
    }
    IOObjectRelease(parent);
    return matches;
}

static kern_return_t CreateRootIterator(io_iterator_t *iterator) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root == MACH_PORT_NULL) {
        return kIOReturnNotFound;
    }
    kern_return_t result = IORegistryEntryCreateIterator(
        root,
        kIOServicePlane,
        kIORegistryIterateRecursively,
        iterator
    );
    IOObjectRelease(root);
    if (result != KERN_SUCCESS && *iterator != MACH_PORT_NULL) {
        IOObjectRelease(*iterator);
        *iterator = MACH_PORT_NULL;
    }
    return result;
}

static IOAVServiceRef CopyDisplayAVService(
    io_service_t adapter,
    uint32_t *chip_address,
    char *error_buffer,
    size_t error_buffer_size
) {
    uint64_t adapter_id = 0;
    if (IORegistryEntryGetRegistryEntryID(adapter, &adapter_id) != KERN_SUCCESS) {
        SetError(error_buffer, error_buffer_size, @"Could not identify Philips IO adapter");
        return NULL;
    }

    io_iterator_t iterator = MACH_PORT_NULL;
    if (CreateRootIterator(&iterator) != KERN_SUCCESS) {
        SetError(error_buffer, error_buffer_size, @"Could not iterate IORegistry");
        return NULL;
    }

    Boolean framebuffer_matches = false;
    IOAVServiceRef result = NULL;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (IOObjectConformsTo(service, "IOMobileFramebuffer")) {
            uint64_t framebuffer_id = 0;
            framebuffer_matches = IORegistryEntryGetRegistryEntryID(
                service,
                &framebuffer_id
            ) == KERN_SUCCESS && framebuffer_id == adapter_id;
            IOObjectRelease(service);
            continue;
        }

        io_name_t name = {0};
        IORegistryEntryGetName(service, name);
        if (!framebuffer_matches || strcmp(name, "DCPAVServiceProxy") != 0) {
            IOObjectRelease(service);
            continue;
        }

        CFTypeRef location = CopyRecursiveProperty(service, CFSTR("Location"));
        Boolean is_external = StringPropertyEquals(location, CFSTR("External"));
        if (location != NULL) {
            CFRelease(location);
        }
        if (!is_external) {
            IOObjectRelease(service);
            continue;
        }

        IOAVServiceRef candidate = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
        if (candidate == NULL) {
            IOObjectRelease(service);
            continue;
        }
        result = candidate;
        *chip_address = IsMCDP29XXProxy(service)
            ? kMCDP29XXChipAddress
            : kDefaultChipAddress;
        IOObjectRelease(service);
        break;
    }
    IOObjectRelease(iterator);

    if (result == NULL) {
        SetError(error_buffer, error_buffer_size, @"Could not find Philips DDC transport");
    }
    return result;
}

int32_t ds_ddc_set_philips_input(
    uint16_t input_value,
    char *error_buffer,
    size_t error_buffer_size
) {
    @autoreleasepool {
        if (error_buffer != NULL && error_buffer_size > 0) {
            error_buffer[0] = '\0';
        }
        if (input_value != 15 && input_value != 18) {
            SetError(error_buffer, error_buffer_size, @"Input value is not allowed");
            return kIOReturnBadArgument;
        }

        void *core_display_handle = NULL;
        CreateDisplayInfoFunction create_display_info =
            ResolveCreateDisplayInfoFunction(&core_display_handle);
        if (create_display_info == NULL) {
            if (core_display_handle != NULL) {
                dlclose(core_display_handle);
            }
            SetError(error_buffer, error_buffer_size, @"CoreDisplay metadata API is unavailable");
            return kIOReturnUnsupported;
        }

        io_service_t adapter = CopyPhilipsAdapter(
            create_display_info,
            error_buffer,
            error_buffer_size
        );
        dlclose(core_display_handle);
        if (adapter == MACH_PORT_NULL) {
            return kIOReturnNotFound;
        }

        uint32_t chip_address = kDefaultChipAddress;
        IOAVServiceRef av_service = CopyDisplayAVService(
            adapter,
            &chip_address,
            error_buffer,
            error_buffer_size
        );
        IOObjectRelease(adapter);
        if (av_service == NULL) {
            return kIOReturnNotFound;
        }

        uint8_t packet[6] = {
            0x84,
            0x03,
            kInputVCPCode,
            (uint8_t)(input_value >> 8),
            (uint8_t)(input_value & 0xFF),
            0,
        };
        packet[5] = 0x6E ^ kInputDataAddress ^ packet[0] ^ packet[1]
            ^ packet[2] ^ packet[3] ^ packet[4];

        IOReturn result = kIOReturnSuccess;
        for (int iteration = 0; iteration < 2; ++iteration) {
            usleep(10000);
            result = IOAVServiceWriteI2C(
                av_service,
                chip_address,
                kInputDataAddress,
                packet,
                sizeof(packet)
            );
            if (result != kIOReturnSuccess) {
                break;
            }
        }
        CFRelease(av_service);

        if (result != kIOReturnSuccess) {
            SetError(
                error_buffer,
                error_buffer_size,
                [NSString stringWithFormat:@"DDC write failed: %s (0x%08x)",
                    mach_error_string(result), result]
            );
        }
        return result;
    }
}
