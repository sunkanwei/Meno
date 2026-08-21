/*
 * Meno Virtual Mouse UMDF 2 HID minidriver.
 *
 * The WDF HID minidriver structure follows Microsoft's vhidmini2 sample,
 * distributed under the Microsoft Public License. See
 * LICENSE-MICROSOFT-SAMPLE.txt.
 */

#pragma once

#include <windows.h>
#include <wdf.h>
#include <hidport.h>

#include "public.h"

typedef UCHAR HID_REPORT_DESCRIPTOR, *PHID_REPORT_DESCRIPTOR;

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD MenoEvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL MenoEvtIoDeviceControl;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL MenoEvtIoOutputReport;
EVT_WDF_TIMER MenoEvtKeyboardWatchdog;

typedef struct _MENO_QUEUED_REPORT {
    UCHAR Length;
    /* Internal only: a replaceable entry is a pure movement (wheel 0, no
       button change) whose position a newer pure movement may overwrite. */
    BOOLEAN Replaceable;
    UCHAR Data[MENO_VIRTUAL_HID_MAX_REPORT_SIZE];
} MENO_QUEUED_REPORT, *PMENO_QUEUED_REPORT;

typedef struct _MENO_DEVICE_CONTEXT {
    WDFQUEUE OutputQueue;
    WDFQUEUE ManualReadQueue;
    WDFWAITLOCK StateLock;
    HID_DEVICE_ATTRIBUTES HidAttributes;
    HID_DESCRIPTOR HidDescriptor;
    MENO_QUEUED_REPORT Reports[MENO_VIRTUAL_MOUSE_QUEUE_CAPACITY];
    ULONG Head;
    ULONG Tail;
    ULONG Count;
    UCHAR Buttons;
    USHORT CurrentX;
    USHORT CurrentY;
    UCHAR KeyboardModifiers;
    UCHAR KeyboardKeys[MENO_VIRTUAL_KEYBOARD_MAX_KEYS];
    ULONGLONG LastKeyboardUpdateTick;
    ULONGLONG AcceptedReports;
    ULONG MaximumQueueDepth;
    ULONG MergeCount;
    ULONGLONG OutputWrites;
    USHORT LastOutputSequence;
    ULONGLONG LastWriteEnterQpc;
    ULONGLONG LastWriteExitQpc;
    ULONGLONG QpcFrequency;
    ULONG LastWriteDurationUs;
    ULONG MaximumWriteDurationUs;
    NTSTATUS LastWriteStatus;
} MENO_DEVICE_CONTEXT, *PMENO_DEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(MENO_DEVICE_CONTEXT, MenoGetDeviceContext);

NTSTATUS
MenoRequestCopyFromBuffer(
    _In_ WDFREQUEST Request,
    _In_reads_bytes_(Length) const VOID* Buffer,
    _In_ size_t Length);

NTSTATUS
MenoRequestGetHidPacketForRead(
    _In_ WDFREQUEST Request,
    _Out_ HID_XFER_PACKET* Packet);

NTSTATUS
MenoRequestGetHidPacketForWrite(
    _In_ WDFREQUEST Request,
    _Out_ HID_XFER_PACKET* Packet);
