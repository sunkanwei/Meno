/*
 * UMDF HID request marshalling helpers adapted from Microsoft's vhidmini2
 * sample under the Microsoft Public License.
 */

#include "driver.h"

NTSTATUS
MenoRequestGetHidPacketForRead(
    _In_ WDFREQUEST Request,
    _Out_ HID_XFER_PACKET* Packet)
{
    WDFMEMORY inputMemory;
    WDFMEMORY outputMemory;
    size_t inputLength;
    size_t outputLength;
    PVOID inputBuffer;
    PVOID outputBuffer;
    NTSTATUS status;

    status = WdfRequestRetrieveInputMemory(Request, &inputMemory);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    inputBuffer = WdfMemoryGetBuffer(inputMemory, &inputLength);
    if (inputLength < sizeof(UCHAR)) {
        return STATUS_INVALID_BUFFER_SIZE;
    }

    status = WdfRequestRetrieveOutputMemory(Request, &outputMemory);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    outputBuffer = WdfMemoryGetBuffer(outputMemory, &outputLength);

    Packet->reportId = *(PUCHAR)inputBuffer;
    Packet->reportBuffer = (PUCHAR)outputBuffer;
    Packet->reportBufferLen = (ULONG)outputLength;
    return STATUS_SUCCESS;
}

NTSTATUS
MenoRequestGetHidPacketForWrite(
    _In_ WDFREQUEST Request,
    _Out_ HID_XFER_PACKET* Packet)
{
    WDFMEMORY inputMemory;
    WDFMEMORY outputMemory;
    size_t inputLength;
    size_t outputLength;
    PVOID inputBuffer;
    NTSTATUS status;

    status = WdfRequestRetrieveOutputMemory(Request, &outputMemory);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    WdfMemoryGetBuffer(outputMemory, &outputLength);

    status = WdfRequestRetrieveInputMemory(Request, &inputMemory);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    inputBuffer = WdfMemoryGetBuffer(inputMemory, &inputLength);

    Packet->reportId = (UCHAR)outputLength;
    Packet->reportBuffer = (PUCHAR)inputBuffer;
    Packet->reportBufferLen = (ULONG)inputLength;
    return STATUS_SUCCESS;
}
