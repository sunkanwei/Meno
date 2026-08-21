/*
 * Meno Virtual Mouse UMDF 2 HID minidriver.
 *
 * The WDF HID minidriver structure and UMDF request handling are based on
 * Microsoft's vhidmini2 sample, distributed under the Microsoft Public
 * License. Meno-specific code supplies an absolute-position mouse collection
 * (no pointer ballistics, matching the QEMU usb-tablet model), a keyboard
 * collection, and a vendor-defined control collection. Continuous mouse and
 * keyboard traffic uses HID output reports; feature reports are read-only
 * diagnostics and compatibility information.
 */

#include <limits.h>

#include "driver.h"

C_ASSERT(sizeof(MENO_VIRTUAL_MOUSE_INFO) == 88);
C_ASSERT(sizeof(MENO_VIRTUAL_MOUSE_SAMPLE) == 8);
C_ASSERT(sizeof(MENO_VIRTUAL_MOUSE_OUTPUT_REPORT) == MENO_VIRTUAL_MOUSE_OUTPUT_REPORT_SIZE);
C_ASSERT(sizeof(MENO_VIRTUAL_MOUSE_HID_REPORT) == MENO_VIRTUAL_MOUSE_HID_REPORT_SIZE);
C_ASSERT(sizeof(MENO_VIRTUAL_KEYBOARD_HID_REPORT) == MENO_VIRTUAL_KEYBOARD_HID_REPORT_SIZE);

static HID_REPORT_DESCRIPTOR MenoReportDescriptor[] = {
    0x06, 0x00, 0xFF, // Usage Page (Vendor Defined 0xFF00)
    0x09, 0x01,       // Usage (Meno Control)
    0xA1, 0x01,       // Collection (Application)
    0x85, MENO_VIRTUAL_MOUSE_CONTROL_REPORT_ID,
    0x09, 0x01,
    0x15, 0x00,
    0x26, 0xFF, 0x00,
    0x75, 0x08,
    0x96,
    (UCHAR)(MENO_VIRTUAL_MOUSE_FEATURE_PAYLOAD_SIZE & 0xFF),
    (UCHAR)(MENO_VIRTUAL_MOUSE_FEATURE_PAYLOAD_SIZE >> 8),
    0xB1, 0x00,       // Feature (Data, Array, Absolute)
    0x85, MENO_VIRTUAL_MOUSE_OUTPUT_REPORT_ID,
    0x09, 0x01,
    0x15, 0x00,
    0x26, 0xFF, 0x00,
    0x75, 0x08,
    0x96,
    (UCHAR)(MENO_VIRTUAL_MOUSE_OUTPUT_PAYLOAD_SIZE & 0xFF),
    (UCHAR)(MENO_VIRTUAL_MOUSE_OUTPUT_PAYLOAD_SIZE >> 8),
    0x91, 0x00,       // Output (Data, Array, Absolute)
    0xC0,

    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x02,       // Usage (Mouse)
    0xA1, 0x01,       // Collection (Application)
    0x85, MENO_VIRTUAL_MOUSE_REPORT_ID,
    0x09, 0x01,       // Usage (Pointer)
    0xA1, 0x00,       // Collection (Physical)
    0x05, 0x09,       // Usage Page (Button)
    0x19, 0x01,
    0x29, 0x03,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x03,
    0x81, 0x02,
    0x75, 0x01,
    0x95, 0x05,
    0x81, 0x03,
    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x30,       // Usage (X)
    0x09, 0x31,       // Usage (Y)
    0x15, 0x00,       // Logical Minimum (0)
    0x26, 0xFF, 0x7F, // Logical Maximum (32767)
    0x35, 0x00,       // Physical Minimum (0)
    0x46, 0xFF, 0x7F, // Physical Maximum (32767)
    0x75, 0x10,
    0x95, 0x02,
    0x81, 0x02,       // Input (Data, Variable, Absolute)
    0x35, 0x00,       // Physical Minimum (0, restore default)
    0x45, 0x00,       // Physical Maximum (0, restore default)
    0x09, 0x38,       // Usage (Wheel)
    0x15, 0x81,
    0x25, 0x7F,
    0x75, 0x08,
    0x95, 0x01,
    0x81, 0x06,
    0xC0,
    0xC0,

    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x06,       // Usage (Keyboard)
    0xA1, 0x01,       // Collection (Application)
    0x85, MENO_VIRTUAL_KEYBOARD_REPORT_ID,
    0x05, 0x07,       // Usage Page (Keyboard/Keypad)
    0x19, 0xE0,       // Usage Minimum (Left Control)
    0x29, 0xE7,       // Usage Maximum (Right GUI)
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x08,
    0x81, 0x02,       // Input (Data, Variable, Absolute)
    0x75, 0x08,
    0x95, 0x01,
    0x81, 0x03,       // Input (Constant)
    0x05, 0x07,
    0x19, 0x00,
    0x29, 0xDF,
    0x15, 0x00,
    0x26, 0xDF, 0x00,
    0x75, 0x08,
    0x95, MENO_VIRTUAL_KEYBOARD_MAX_KEYS,
    0x81, 0x00,       // Input (Data, Array, Absolute)
    0xC0
};

static NTSTATUS
MenoCreateQueues(_In_ WDFDEVICE Device);

static NTSTATUS
MenoReadReport(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request,
    _Out_ BOOLEAN* CompleteRequest);

static NTSTATUS
MenoGetFeature(
    _In_ PMENO_DEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request);

static NTSTATUS
MenoWriteReport(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request,
    _In_ LARGE_INTEGER Entered);

static NTSTATUS
MenoGetInputReport(
    _In_ PMENO_DEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request);

static NTSTATUS
MenoDeliverOrQueue(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_reads_bytes_(Length) const VOID* Report,
    _In_ UCHAR Length);

static NTSTATUS
MenoReset(_Inout_ PMENO_DEVICE_CONTEXT Context);

static NTSTATUS
MenoSetKeyboardState(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_ UCHAR Modifiers,
    _In_reads_(KeyCount) const UCHAR* Keys,
    _In_ UCHAR KeyCount);

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;

    WDF_DRIVER_CONFIG_INIT(&config, MenoEvtDeviceAdd);
    return WdfDriverCreate(
        DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        WDF_NO_HANDLE);
}

NTSTATUS
MenoEvtDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit)
{
    WDF_OBJECT_ATTRIBUTES attributes;
    PMENO_DEVICE_CONTEXT context;
    WDFDEVICE device;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Driver);

    WdfFdoInitSetFilter(DeviceInit);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, MENO_DEVICE_CONTEXT);
    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    context = MenoGetDeviceContext(device);
    context->CurrentX = MENO_VIRTUAL_MOUSE_ABSOLUTE_MAX / 2;
    context->CurrentY = MENO_VIRTUAL_MOUSE_ABSOLUTE_MAX / 2;
    context->HidAttributes.Size = sizeof(HID_DEVICE_ATTRIBUTES);
    context->HidAttributes.VendorID = MENO_VIRTUAL_MOUSE_VID;
    context->HidAttributes.ProductID = MENO_VIRTUAL_MOUSE_PID;
    context->HidAttributes.VersionNumber = MENO_VIRTUAL_MOUSE_DEVICE_VERSION;
    {
        LARGE_INTEGER frequency;
        if (QueryPerformanceFrequency(&frequency)) {
            context->QpcFrequency = (ULONGLONG)frequency.QuadPart;
        }
    }
    context->LastWriteStatus = STATUS_SUCCESS;

    context->HidDescriptor.bLength = sizeof(HID_DESCRIPTOR);
    context->HidDescriptor.bDescriptorType = 0x21;
    context->HidDescriptor.bcdHID = 0x0111;
    context->HidDescriptor.bCountry = 0;
    context->HidDescriptor.bNumDescriptors = 1;
    context->HidDescriptor.DescriptorList[0].bReportType = 0x22;
    context->HidDescriptor.DescriptorList[0].wReportLength =
        (USHORT)sizeof(MenoReportDescriptor);

    return MenoCreateQueues(device);
}

static NTSTATUS
MenoCreateQueues(_In_ WDFDEVICE Device)
{
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDF_OBJECT_ATTRIBUTES lockAttributes;
    WDF_OBJECT_ATTRIBUTES timerAttributes;
    WDF_TIMER_CONFIG timerConfig;
    WDFTIMER keyboardWatchdogTimer;
    PMENO_DEVICE_CONTEXT context = MenoGetDeviceContext(Device);
    NTSTATUS status;

    /* Mutable report state is protected explicitly so unrelated HID requests
       never share a device-wide dispatcher lock. */
    WDF_OBJECT_ATTRIBUTES_INIT(&lockAttributes);
    lockAttributes.ParentObject = Device;
    status = WdfWaitLockCreate(&lockAttributes, &context->StateLock);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT(&queueConfig, WdfIoQueueDispatchManual);
    status = WdfIoQueueCreate(
        Device,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        &context->ManualReadQueue);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    /* Output reports are ordered state transitions and must remain sequential. */
    WDF_IO_QUEUE_CONFIG_INIT(&queueConfig, WdfIoQueueDispatchSequential);
    queueConfig.EvtIoDeviceControl = MenoEvtIoOutputReport;
    status = WdfIoQueueCreate(
        Device,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        &context->OutputQueue);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    /* The default queue stays parallel so reads and diagnostics cannot
       head-of-line block output reports before they reach OutputQueue. */
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(
        &queueConfig,
        WdfIoQueueDispatchParallel);
    queueConfig.EvtIoDeviceControl = MenoEvtIoDeviceControl;
    status = WdfIoQueueCreate(
        Device,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WDF_TIMER_CONFIG_INIT_PERIODIC(
        &timerConfig,
        MenoEvtKeyboardWatchdog,
        MENO_VIRTUAL_KEYBOARD_TIMER_MS);
    timerConfig.AutomaticSerialization = FALSE;
    WDF_OBJECT_ATTRIBUTES_INIT(&timerAttributes);
    timerAttributes.ParentObject = Device;
    status = WdfTimerCreate(
        &timerConfig,
        &timerAttributes,
        &keyboardWatchdogTimer);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    WdfTimerStart(
        keyboardWatchdogTimer,
        WDF_REL_TIMEOUT_IN_MS(MENO_VIRTUAL_KEYBOARD_TIMER_MS));
    return STATUS_SUCCESS;
}

VOID
MenoEvtIoDeviceControl(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode)
{
    PMENO_DEVICE_CONTEXT context =
        MenoGetDeviceContext(WdfIoQueueGetDevice(Queue));
    BOOLEAN completeRequest = TRUE;
    BOOLEAN stateLocked = FALSE;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    switch (IoControlCode) {
    case IOCTL_HID_GET_DEVICE_DESCRIPTOR:
        status = MenoRequestCopyFromBuffer(
            Request,
            &context->HidDescriptor,
            context->HidDescriptor.bLength);
        break;

    case IOCTL_HID_GET_DEVICE_ATTRIBUTES:
        status = MenoRequestCopyFromBuffer(
            Request,
            &context->HidAttributes,
            sizeof(context->HidAttributes));
        break;

    case IOCTL_HID_GET_REPORT_DESCRIPTOR:
        status = MenoRequestCopyFromBuffer(
            Request,
            MenoReportDescriptor,
            sizeof(MenoReportDescriptor));
        break;

    case IOCTL_HID_READ_REPORT:
        status = WdfWaitLockAcquire(context->StateLock, NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }
        stateLocked = TRUE;
        status = MenoReadReport(context, Request, &completeRequest);
        break;

    case IOCTL_HID_WRITE_REPORT:
    case IOCTL_UMDF_HID_SET_OUTPUT_REPORT:
        status = WdfRequestForwardToIoQueue(Request, context->OutputQueue);
        completeRequest = !NT_SUCCESS(status);
        break;

    case IOCTL_UMDF_HID_GET_FEATURE:
        status = WdfWaitLockAcquire(context->StateLock, NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }
        stateLocked = TRUE;
        status = MenoGetFeature(context, Request);
        break;

    case IOCTL_UMDF_HID_SET_FEATURE:
        status = STATUS_NOT_SUPPORTED;
        break;

    case IOCTL_UMDF_HID_GET_INPUT_REPORT:
        status = WdfWaitLockAcquire(context->StateLock, NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }
        stateLocked = TRUE;
        status = MenoGetInputReport(context, Request);
        break;

    case IOCTL_HID_ACTIVATE_DEVICE:
    case IOCTL_HID_DEACTIVATE_DEVICE:
        status = STATUS_SUCCESS;
        break;

    default:
        status = STATUS_NOT_SUPPORTED;
        break;
    }

    if (stateLocked) {
        WdfWaitLockRelease(context->StateLock);
    }
    if (completeRequest) {
        WdfRequestComplete(Request, status);
    }
}

VOID
MenoEvtIoOutputReport(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode)
{
    PMENO_DEVICE_CONTEXT context =
        MenoGetDeviceContext(WdfIoQueueGetDevice(Queue));
    LARGE_INTEGER entered;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    QueryPerformanceCounter(&entered);
    if (IoControlCode != IOCTL_HID_WRITE_REPORT
        && IoControlCode != IOCTL_UMDF_HID_SET_OUTPUT_REPORT) {
        WdfRequestComplete(Request, STATUS_NOT_SUPPORTED);
        return;
    }

    status = WdfWaitLockAcquire(context->StateLock, NULL);
    if (NT_SUCCESS(status)) {
        status = MenoWriteReport(context, Request, entered);
        WdfWaitLockRelease(context->StateLock);
    }
    WdfRequestComplete(Request, status);
}

NTSTATUS
MenoRequestCopyFromBuffer(
    _In_ WDFREQUEST Request,
    _In_reads_bytes_(Length) const VOID* Buffer,
    _In_ size_t Length)
{
    WDFMEMORY memory;
    size_t outputLength;
    NTSTATUS status;

    status = WdfRequestRetrieveOutputMemory(Request, &memory);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    WdfMemoryGetBuffer(memory, &outputLength);
    if (outputLength < Length) {
        return STATUS_BUFFER_TOO_SMALL;
    }
    status = WdfMemoryCopyFromBuffer(memory, 0, (PVOID)Buffer, Length);
    if (NT_SUCCESS(status)) {
        WdfRequestSetInformation(Request, Length);
    }
    return status;
}

static BOOLEAN
MenoPopReport(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _Out_ PMENO_QUEUED_REPORT Report)
{
    if (Context->Count == 0) {
        RtlZeroMemory(Report, sizeof(*Report));
        return FALSE;
    }
    *Report = Context->Reports[Context->Head];
    Context->Head = (Context->Head + 1) % MENO_VIRTUAL_MOUSE_QUEUE_CAPACITY;
    Context->Count--;
    return TRUE;
}

static BOOLEAN
MenoIsPureMovement(
    _In_ PMENO_DEVICE_CONTEXT Context,
    _In_reads_bytes_(Length) const VOID* Report,
    _In_ UCHAR Length)
{
    MENO_VIRTUAL_MOUSE_HID_REPORT mouse;

    if (Length != MENO_VIRTUAL_MOUSE_HID_REPORT_SIZE) {
        return FALSE;
    }
    RtlCopyMemory(&mouse, Report, sizeof(mouse));
    /* A pure movement carries no wheel delta and does not change the button
       state already committed, so only its position matters. */
    return mouse.ReportId == MENO_VIRTUAL_MOUSE_REPORT_ID
        && mouse.Wheel == 0
        && mouse.Buttons == Context->Buttons;
}

static NTSTATUS
MenoQueueReport(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_reads_bytes_(Length) const VOID* Report,
    _In_ UCHAR Length)
{
    PMENO_QUEUED_REPORT queued;
    PMENO_QUEUED_REPORT last;
    MENO_VIRTUAL_MOUSE_HID_REPORT currentMouse;
    MENO_VIRTUAL_MOUSE_HID_REPORT lastMouse;
    ULONG index;
    BOOLEAN replaceable;

    if (Length == 0 || Length > MENO_VIRTUAL_HID_MAX_REPORT_SIZE) {
        return STATUS_INVALID_BUFFER_SIZE;
    }

    /* A stalled reader must never replay stale positions: a new pure
       movement immediately overwrites a replaceable tail with the same
       button state, instead of waiting for a full queue. */
    replaceable = MenoIsPureMovement(Context, Report, Length);
    if (replaceable && Context->Count != 0) {
        index = (Context->Tail + MENO_VIRTUAL_MOUSE_QUEUE_CAPACITY - 1)
            % MENO_VIRTUAL_MOUSE_QUEUE_CAPACITY;
        last = &Context->Reports[index];
        if (last->Replaceable) {
            RtlCopyMemory(&currentMouse, Report, sizeof(currentMouse));
            RtlCopyMemory(&lastMouse, last->Data, sizeof(lastMouse));
            if (lastMouse.Buttons == currentMouse.Buttons) {
                lastMouse.X = currentMouse.X;
                lastMouse.Y = currentMouse.Y;
                RtlCopyMemory(last->Data, &lastMouse, sizeof(lastMouse));
                Context->MergeCount++;
                Context->AcceptedReports++;
                return STATUS_SUCCESS;
            }
        }
    }

    /* Button, wheel, keyboard and reset reports are never replaceable, and a
       pure movement never crosses them; a full queue of those is an error. */
    if (Context->Count == MENO_VIRTUAL_MOUSE_QUEUE_CAPACITY) {
        return STATUS_BUFFER_OVERFLOW;
    }

    queued = &Context->Reports[Context->Tail];
    queued->Length = Length;
    queued->Replaceable = replaceable;
    RtlZeroMemory(queued->Data, sizeof(queued->Data));
    RtlCopyMemory(queued->Data, Report, Length);
    Context->Tail = (Context->Tail + 1) % MENO_VIRTUAL_MOUSE_QUEUE_CAPACITY;
    Context->Count++;
    Context->AcceptedReports++;
    if (Context->Count > Context->MaximumQueueDepth) {
        Context->MaximumQueueDepth = Context->Count;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
MenoReadReport(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request,
    _Out_ BOOLEAN* CompleteRequest)
{
    MENO_QUEUED_REPORT report;
    NTSTATUS status;

    if (MenoPopReport(Context, &report)) {
        *CompleteRequest = TRUE;
        return MenoRequestCopyFromBuffer(Request, report.Data, report.Length);
    }

    status = WdfRequestForwardToIoQueue(Request, Context->ManualReadQueue);
    *CompleteRequest = !NT_SUCCESS(status);
    return status;
}

static NTSTATUS
MenoCompletePendingRead(
    _In_ WDFREQUEST Request,
    _In_reads_bytes_(Length) const VOID* Report,
    _In_ UCHAR Length)
{
    NTSTATUS status = MenoRequestCopyFromBuffer(Request, Report, Length);
    WdfRequestComplete(Request, status);
    return status;
}

static NTSTATUS
MenoDeliverOrQueue(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_reads_bytes_(Length) const VOID* Report,
    _In_ UCHAR Length)
{
    WDFREQUEST request;
    NTSTATUS status;

    status = WdfIoQueueRetrieveNextRequest(Context->ManualReadQueue, &request);
    if (NT_SUCCESS(status)) {
        status = MenoCompletePendingRead(request, Report, Length);
        if (NT_SUCCESS(status)) {
            Context->AcceptedReports++;
        }
        return status;
    }
    if (status != STATUS_NO_MORE_ENTRIES) {
        return status;
    }
    return MenoQueueReport(Context, Report, Length);
}

static NTSTATUS
MenoGetFeature(
    _In_ PMENO_DEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request)
{
    HID_XFER_PACKET packet;
    PMENO_VIRTUAL_MOUSE_INFO info;
    NTSTATUS status;

    status = MenoRequestGetHidPacketForRead(Request, &packet);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    if (packet.reportId != MENO_VIRTUAL_MOUSE_CONTROL_REPORT_ID) {
        return STATUS_INVALID_PARAMETER;
    }
    if (packet.reportBufferLen < MENO_VIRTUAL_MOUSE_CONTROL_REPORT_SIZE) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    RtlZeroMemory(packet.reportBuffer, MENO_VIRTUAL_MOUSE_CONTROL_REPORT_SIZE);
    packet.reportBuffer[0] = MENO_VIRTUAL_MOUSE_CONTROL_REPORT_ID;
    info = (PMENO_VIRTUAL_MOUSE_INFO)(packet.reportBuffer + 1);
    info->Abi = MENO_VIRTUAL_MOUSE_ABI;
    info->VersionMajor = MENO_VIRTUAL_MOUSE_VERSION_MAJOR;
    info->VersionMinor = MENO_VIRTUAL_MOUSE_VERSION_MINOR;
    info->VersionPatch = MENO_VIRTUAL_MOUSE_VERSION_PATCH;
    info->Capabilities = MENO_VIRTUAL_MOUSE_CAP_ABSOLUTE_XY
        | MENO_VIRTUAL_MOUSE_CAP_BUTTONS
        | MENO_VIRTUAL_MOUSE_CAP_VERTICAL_WHEEL
        | MENO_VIRTUAL_MOUSE_CAP_BATCH
        | MENO_VIRTUAL_MOUSE_CAP_UMDF
        | MENO_VIRTUAL_MOUSE_CAP_KEYBOARD
        | MENO_VIRTUAL_MOUSE_CAP_KEYBOARD_WATCHDOG
        | MENO_VIRTUAL_MOUSE_CAP_OUTPUT_REPORT
        | MENO_VIRTUAL_MOUSE_CAP_PATH_DIAGNOSTICS;
    info->MaximumBatch = MENO_VIRTUAL_MOUSE_MAX_BATCH;
    info->QueueCapacity = MENO_VIRTUAL_MOUSE_QUEUE_CAPACITY;
    info->MouseReportSize = MENO_VIRTUAL_MOUSE_HID_REPORT_SIZE;
    info->KeyboardReportSize = MENO_VIRTUAL_KEYBOARD_HID_REPORT_SIZE;
    info->AcceptedReports = Context->AcceptedReports;
    info->MaximumQueueDepth = Context->MaximumQueueDepth;
    info->MergeCount = Context->MergeCount;
    info->CurrentQueueDepth = Context->Count;
    info->OutputWrites = Context->OutputWrites;
    info->LastOutputSequence = Context->LastOutputSequence;
    info->DiagnosticsReserved = 0;
    info->LastWriteEnterQpc = Context->LastWriteEnterQpc;
    info->LastWriteExitQpc = Context->LastWriteExitQpc;
    info->QpcFrequency = Context->QpcFrequency;
    info->LastWriteDurationUs = Context->LastWriteDurationUs;
    info->MaximumWriteDurationUs = Context->MaximumWriteDurationUs;
    info->LastWriteStatus = Context->LastWriteStatus;
    WdfRequestSetInformation(Request, MENO_VIRTUAL_MOUSE_CONTROL_REPORT_SIZE);
    return STATUS_SUCCESS;
}

static NTSTATUS
MenoValidateOutputReport(
    _In_ const MENO_VIRTUAL_MOUSE_OUTPUT_REPORT* Output)
{
    const MENO_VIRTUAL_MOUSE_SAMPLE* samples =
        (const MENO_VIRTUAL_MOUSE_SAMPLE*)Output->Payload;
    ULONG index;
    ULONG other;

    if (Output->ReportId != MENO_VIRTUAL_MOUSE_OUTPUT_REPORT_ID
        || Output->Version != MENO_VIRTUAL_MOUSE_REPORT_VERSION) {
        return STATUS_INVALID_PARAMETER;
    }
    if (Output->Command == MENO_VIRTUAL_MOUSE_COMMAND_RESET) {
        if (Output->Flags != 0 || Output->Count > 1) {
            return STATUS_INVALID_PARAMETER;
        }
        if (Output->Count == 1
            && (samples[0].Buttons != 0
                || samples[0].Wheel != 0
                || samples[0].Flags != 0
                || samples[0].Reserved != 0
                || samples[0].X > MENO_VIRTUAL_MOUSE_ABSOLUTE_MAX
                || samples[0].Y > MENO_VIRTUAL_MOUSE_ABSOLUTE_MAX)) {
            return STATUS_INVALID_PARAMETER;
        }
        return STATUS_SUCCESS;
    }
    if (Output->Command == MENO_VIRTUAL_KEYBOARD_COMMAND_STATE) {
        if (Output->Count > MENO_VIRTUAL_KEYBOARD_MAX_KEYS) {
            return STATUS_INVALID_PARAMETER;
        }
        for (index = 0; index < MENO_VIRTUAL_KEYBOARD_MAX_KEYS; index++) {
            if (index >= Output->Count) {
                if (Output->Payload[index] != 0) {
                    return STATUS_INVALID_PARAMETER;
                }
                continue;
            }
            if (Output->Payload[index] < 0x04
                || Output->Payload[index] >= 0xE0) {
                return STATUS_INVALID_PARAMETER;
            }
            for (other = index + 1; other < Output->Count; other++) {
                if (Output->Payload[index] == Output->Payload[other]) {
                    return STATUS_INVALID_PARAMETER;
                }
            }
        }
        return STATUS_SUCCESS;
    }
    if (Output->Command != MENO_VIRTUAL_MOUSE_COMMAND_SUBMIT
        || Output->Flags != 0
        || Output->Count == 0
        || Output->Count > MENO_VIRTUAL_MOUSE_MAX_BATCH) {
        return STATUS_INVALID_PARAMETER;
    }
    for (index = 0; index < Output->Count; index++) {
        const MENO_VIRTUAL_MOUSE_SAMPLE* sample = &samples[index];
        if ((sample->Buttons & ~0x07u) != 0
            || sample->Flags != 0
            || sample->Reserved != 0
            || sample->X > MENO_VIRTUAL_MOUSE_ABSOLUTE_MAX
            || sample->Y > MENO_VIRTUAL_MOUSE_ABSOLUTE_MAX
            || sample->Wheel == SCHAR_MIN) {
            return STATUS_INVALID_PARAMETER;
        }
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
MenoWriteReport(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request,
    _In_ LARGE_INTEGER Entered)
{
    HID_XFER_PACKET packet;
    PMENO_VIRTUAL_MOUSE_OUTPUT_REPORT output;
    LARGE_INTEGER exited;
    ULONGLONG durationUs;
    NTSTATUS status;
    ULONG index;

    status = MenoRequestGetHidPacketForWrite(Request, &packet);
    if (!NT_SUCCESS(status)) {
        goto Exit;
    }
    if (packet.reportId != MENO_VIRTUAL_MOUSE_OUTPUT_REPORT_ID
        || packet.reportBufferLen < MENO_VIRTUAL_MOUSE_OUTPUT_REPORT_SIZE) {
        status = STATUS_INVALID_BUFFER_SIZE;
        goto Exit;
    }

    output = (PMENO_VIRTUAL_MOUSE_OUTPUT_REPORT)packet.reportBuffer;
    Context->LastOutputSequence = output->Sequence;
    status = MenoValidateOutputReport(output);
    if (!NT_SUCCESS(status)) {
        goto Exit;
    }

    if (output->Command == MENO_VIRTUAL_MOUSE_COMMAND_RESET) {
        if (output->Count == 1) {
            const MENO_VIRTUAL_MOUSE_SAMPLE* position =
                (const MENO_VIRTUAL_MOUSE_SAMPLE*)output->Payload;
            Context->CurrentX = position->X;
            Context->CurrentY = position->Y;
        }
        status = MenoReset(Context);
    } else if (output->Command == MENO_VIRTUAL_KEYBOARD_COMMAND_STATE) {
        status = MenoSetKeyboardState(
            Context,
            output->Flags,
            output->Payload,
            output->Count);
    } else {
        const MENO_VIRTUAL_MOUSE_SAMPLE* samples =
            (const MENO_VIRTUAL_MOUSE_SAMPLE*)output->Payload;
        for (index = 0; index < output->Count; index++) {
            const MENO_VIRTUAL_MOUSE_SAMPLE* sample = &samples[index];
            MENO_VIRTUAL_MOUSE_HID_REPORT report;

            report.ReportId = MENO_VIRTUAL_MOUSE_REPORT_ID;
            report.Buttons = sample->Buttons;
            report.X = sample->X;
            report.Y = sample->Y;
            report.Wheel = sample->Wheel;
            status = MenoDeliverOrQueue(Context, &report, sizeof(report));
            if (!NT_SUCCESS(status)) {
                goto Exit;
            }
            Context->Buttons = report.Buttons;
            Context->CurrentX = report.X;
            Context->CurrentY = report.Y;
        }
    }

    if (NT_SUCCESS(status)) {
        WdfRequestSetInformation(Request, MENO_VIRTUAL_MOUSE_OUTPUT_REPORT_SIZE);
    }

Exit:
    QueryPerformanceCounter(&exited);
    Context->OutputWrites++;
    Context->LastWriteEnterQpc = (ULONGLONG)Entered.QuadPart;
    Context->LastWriteExitQpc = (ULONGLONG)exited.QuadPart;
    Context->LastWriteStatus = status;
    durationUs = 0;
    if (Context->QpcFrequency != 0 && exited.QuadPart >= Entered.QuadPart) {
        durationUs = ((ULONGLONG)(exited.QuadPart - Entered.QuadPart) * 1000000u)
            / Context->QpcFrequency;
    }
    Context->LastWriteDurationUs = durationUs > ULONG_MAX
        ? ULONG_MAX
        : (ULONG)durationUs;
    if (Context->LastWriteDurationUs > Context->MaximumWriteDurationUs) {
        Context->MaximumWriteDurationUs = Context->LastWriteDurationUs;
    }
    return status;
}

static NTSTATUS
MenoGetInputReport(
    _In_ PMENO_DEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request)
{
    HID_XFER_PACKET packet;
    NTSTATUS status;

    status = MenoRequestGetHidPacketForRead(Request, &packet);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    if (packet.reportId == MENO_VIRTUAL_MOUSE_REPORT_ID) {
        MENO_VIRTUAL_MOUSE_HID_REPORT report;

        if (packet.reportBufferLen < sizeof(report)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        report.ReportId = MENO_VIRTUAL_MOUSE_REPORT_ID;
        report.Buttons = Context->Buttons;
        report.X = Context->CurrentX;
        report.Y = Context->CurrentY;
        report.Wheel = 0;
        RtlCopyMemory(packet.reportBuffer, &report, sizeof(report));
        WdfRequestSetInformation(Request, sizeof(report));
        return STATUS_SUCCESS;
    }
    if (packet.reportId == MENO_VIRTUAL_KEYBOARD_REPORT_ID) {
        MENO_VIRTUAL_KEYBOARD_HID_REPORT report;

        if (packet.reportBufferLen < sizeof(report)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        report.ReportId = MENO_VIRTUAL_KEYBOARD_REPORT_ID;
        report.Modifiers = Context->KeyboardModifiers;
        report.Reserved = 0;
        RtlCopyMemory(report.Keys, Context->KeyboardKeys, sizeof(report.Keys));
        RtlCopyMemory(packet.reportBuffer, &report, sizeof(report));
        WdfRequestSetInformation(Request, sizeof(report));
        return STATUS_SUCCESS;
    }
    return STATUS_INVALID_PARAMETER;
}

static NTSTATUS
MenoReset(_Inout_ PMENO_DEVICE_CONTEXT Context)
{
    MENO_VIRTUAL_MOUSE_HID_REPORT mouseReport;
    MENO_VIRTUAL_KEYBOARD_HID_REPORT keyboardReport;
    NTSTATUS status;

    Context->Head = 0;
    Context->Tail = 0;
    Context->Count = 0;
    Context->Buttons = 0;
    Context->KeyboardModifiers = 0;
    RtlZeroMemory(Context->KeyboardKeys, sizeof(Context->KeyboardKeys));
    Context->LastKeyboardUpdateTick = GetTickCount64();

    mouseReport.ReportId = MENO_VIRTUAL_MOUSE_REPORT_ID;
    mouseReport.Buttons = 0;
    /* Absolute mode: a reset must hold the current position, not zero it. */
    mouseReport.X = Context->CurrentX;
    mouseReport.Y = Context->CurrentY;
    mouseReport.Wheel = 0;
    status = MenoDeliverOrQueue(Context, &mouseReport, sizeof(mouseReport));
    if (!NT_SUCCESS(status)) {
        return status;
    }

    keyboardReport.ReportId = MENO_VIRTUAL_KEYBOARD_REPORT_ID;
    keyboardReport.Modifiers = 0;
    keyboardReport.Reserved = 0;
    RtlZeroMemory(keyboardReport.Keys, sizeof(keyboardReport.Keys));
    return MenoDeliverOrQueue(Context, &keyboardReport, sizeof(keyboardReport));
}

static VOID
MenoSortKeyboardKeys(
    _Inout_updates_(KeyCount) UCHAR* Keys,
    _In_ UCHAR KeyCount)
{
    UCHAR index;

    for (index = 1; index < KeyCount; index++) {
        UCHAR position = index;
        UCHAR value = Keys[index];
        while (position > 0 && Keys[position - 1] > value) {
            Keys[position] = Keys[position - 1];
            position--;
        }
        Keys[position] = value;
    }
}

static NTSTATUS
MenoSetKeyboardState(
    _Inout_ PMENO_DEVICE_CONTEXT Context,
    _In_ UCHAR Modifiers,
    _In_reads_(KeyCount) const UCHAR* Keys,
    _In_ UCHAR KeyCount)
{
    MENO_VIRTUAL_KEYBOARD_HID_REPORT report;
    BOOLEAN changed;
    BOOLEAN neutral;
    NTSTATUS status;

    report.ReportId = MENO_VIRTUAL_KEYBOARD_REPORT_ID;
    report.Modifiers = Modifiers;
    report.Reserved = 0;
    RtlZeroMemory(report.Keys, sizeof(report.Keys));
    if (KeyCount != 0) {
        RtlCopyMemory(report.Keys, Keys, KeyCount);
        MenoSortKeyboardKeys(report.Keys, KeyCount);
    }

    changed = Context->KeyboardModifiers != report.Modifiers
        || RtlCompareMemory(
            Context->KeyboardKeys,
            report.Keys,
            sizeof(report.Keys)) != sizeof(report.Keys);
    if (!changed) {
        Context->LastKeyboardUpdateTick = GetTickCount64();
        return STATUS_SUCCESS;
    }

    neutral = report.Modifiers == 0 && KeyCount == 0;
    status = MenoDeliverOrQueue(Context, &report, sizeof(report));
    if (status == STATUS_BUFFER_OVERFLOW && neutral) {
        Context->Head = 0;
        Context->Tail = 0;
        Context->Count = 0;
        status = MenoDeliverOrQueue(Context, &report, sizeof(report));
    }
    if (NT_SUCCESS(status)) {
        Context->KeyboardModifiers = report.Modifiers;
        RtlCopyMemory(
            Context->KeyboardKeys,
            report.Keys,
            sizeof(Context->KeyboardKeys));
        Context->LastKeyboardUpdateTick = GetTickCount64();
    }
    return status;
}

VOID
MenoEvtKeyboardWatchdog(_In_ WDFTIMER Timer)
{
    static const UCHAR zeroKeys[MENO_VIRTUAL_KEYBOARD_MAX_KEYS] = { 0 };
    WDFDEVICE device = (WDFDEVICE)WdfTimerGetParentObject(Timer);
    PMENO_DEVICE_CONTEXT context = MenoGetDeviceContext(device);
    MENO_VIRTUAL_KEYBOARD_HID_REPORT report;
    ULONGLONG now;
    NTSTATUS status;

    status = WdfWaitLockAcquire(context->StateLock, NULL);
    if (!NT_SUCCESS(status)) {
        return;
    }

    if (context->KeyboardModifiers == 0
        && RtlCompareMemory(
            context->KeyboardKeys,
            zeroKeys,
            sizeof(context->KeyboardKeys)) == sizeof(context->KeyboardKeys)) {
        goto Exit;
    }
    now = GetTickCount64();
    if (now - context->LastKeyboardUpdateTick < MENO_VIRTUAL_KEYBOARD_WATCHDOG_MS) {
        goto Exit;
    }

    context->KeyboardModifiers = 0;
    RtlZeroMemory(context->KeyboardKeys, sizeof(context->KeyboardKeys));
    context->LastKeyboardUpdateTick = now;

    /* A stale key release is safety-critical. Drop queued motion if needed so
       the neutral keyboard state cannot be blocked behind a full queue. */
    context->Head = 0;
    context->Tail = 0;
    context->Count = 0;
    report.ReportId = MENO_VIRTUAL_KEYBOARD_REPORT_ID;
    report.Modifiers = 0;
    report.Reserved = 0;
    RtlZeroMemory(report.Keys, sizeof(report.Keys));
    (VOID)MenoDeliverOrQueue(context, &report, sizeof(report));

Exit:
    WdfWaitLockRelease(context->StateLock);
}
