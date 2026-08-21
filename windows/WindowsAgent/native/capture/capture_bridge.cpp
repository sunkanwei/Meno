#define NOMINMAX
#include <Windows.h>
#include <d3d11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <vector>

struct CaptureBuffer { std::uint8_t* data; std::uint32_t width, height, stride; };
struct CaptureTargetInfo {
    std::uint64_t id; std::int32_t x, y; std::uint32_t width, height, flags; char title[512];
};

namespace {
using namespace winrt;
using namespace winrt::Windows::Graphics;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;
struct ApartmentGuard { ~ApartmentGuard() { uninit_apartment(); } };

IDirect3DDevice create_device(com_ptr<ID3D11Device>& d3d) {
    com_ptr<ID3D11DeviceContext> context;
    check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        d3d.put(), nullptr, context.put()));
    auto dxgi = d3d.as<IDXGIDevice>(); com_ptr<IInspectable> inspectable;
    check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
    return inspectable.as<IDirect3DDevice>();
}

GraphicsCaptureItem monitor_item(HMONITOR monitor) {
    auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    GraphicsCaptureItem item{nullptr};
    check_hresult(interop->CreateForMonitor(monitor, guid_of<GraphicsCaptureItem>(), put_abi(item)));
    return item;
}
GraphicsCaptureItem window_item(HWND window) {
    auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    GraphicsCaptureItem item{nullptr};
    check_hresult(interop->CreateForWindow(window, guid_of<GraphicsCaptureItem>(), put_abi(item)));
    return item;
}

std::int32_t capture_item(const GraphicsCaptureItem& item, CaptureBuffer* output) {
    com_ptr<ID3D11Device> d3d; const auto device = create_device(d3d); const auto size = item.Size();
    if (size.Width <= 0 || size.Height <= 0) throw_hresult(E_INVALIDARG);
    auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(device,
        DirectXPixelFormat::B8G8R8A8UIntNormalized, 1, size);
    auto session = pool.CreateCaptureSession(item);
    auto event = std::make_shared<handle>(check_pointer(CreateEventW(nullptr, TRUE, FALSE, nullptr)));
    const auto token = pool.FrameArrived([event](const auto&, const auto&) { SetEvent(event->get()); });
    session.StartCapture(); const auto waited = WaitForSingleObject(event->get(), 3000);
    if (waited != WAIT_OBJECT_0) {
        pool.FrameArrived(token); session.Close(); pool.Close();
        throw_hresult(waited == WAIT_TIMEOUT ? HRESULT_FROM_WIN32(WAIT_TIMEOUT) : E_FAIL);
    }
    const auto frame = pool.TryGetNextFrame(); pool.FrameArrived(token);
    if (frame == nullptr) throw_hresult(E_FAIL);
    const auto access = frame.Surface().as<
        ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    com_ptr<ID3D11Texture2D> source;
    check_hresult(access->GetInterface(guid_of<ID3D11Texture2D>(), source.put_void()));
    D3D11_TEXTURE2D_DESC desc{}; source->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ; desc.MiscFlags = 0;
    com_ptr<ID3D11Texture2D> staging; check_hresult(d3d->CreateTexture2D(&desc, nullptr, staging.put()));
    com_ptr<ID3D11DeviceContext> context; d3d->GetImmediateContext(context.put());
    context->CopyResource(staging.get(), source.get());
    D3D11_MAPPED_SUBRESOURCE mapped{}; check_hresult(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped));
    const auto stride = static_cast<std::uint64_t>(desc.Width) * 4;
    const auto bytes = stride * desc.Height;
    if (stride > UINT32_MAX || bytes > SIZE_MAX) { context->Unmap(staging.get(), 0); throw_hresult(E_OUTOFMEMORY); }
    auto pixels = new (std::nothrow) std::uint8_t[static_cast<std::size_t>(bytes)];
    if (!pixels) { context->Unmap(staging.get(), 0); throw_hresult(E_OUTOFMEMORY); }
    for (std::uint32_t row = 0; row < desc.Height; ++row)
        std::memcpy(pixels + row * stride, static_cast<const std::uint8_t*>(mapped.pData) + row * mapped.RowPitch,
            static_cast<std::size_t>(stride));
    context->Unmap(staging.get(), 0); session.Close(); pool.Close();
    output->data = pixels; output->width = desc.Width; output->height = desc.Height;
    output->stride = static_cast<std::uint32_t>(stride); return S_OK;
}

std::vector<HMONITOR> monitors() {
    std::vector<HMONITOR> result;
    EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR monitor, HDC, LPRECT, LPARAM value) {
        reinterpret_cast<std::vector<HMONITOR>*>(value)->push_back(monitor); return TRUE;
    }, reinterpret_cast<LPARAM>(&result)); return result;
}
std::vector<HWND> windows() {
    std::vector<HWND> result;
    EnumWindows([](HWND window, LPARAM value) {
        RECT rect{};
        if (IsWindowVisible(window) && GetWindowTextLengthW(window) > 0 && GetWindowRect(window, &rect)
            && rect.right > rect.left && rect.bottom > rect.top)
            reinterpret_cast<std::vector<HWND>*>(value)->push_back(window);
        return TRUE;
    }, reinterpret_cast<LPARAM>(&result)); return result;
}
}

extern "C" std::uint32_t get_monitor_count() noexcept { return static_cast<std::uint32_t>(monitors().size()); }
extern "C" std::uint32_t get_window_count() noexcept { return static_cast<std::uint32_t>(windows().size()); }
extern "C" std::int32_t get_monitor_info(std::uint32_t index, CaptureTargetInfo* output) noexcept {
    if (!output) return E_INVALIDARG; *output = {}; auto list = monitors(); if (index >= list.size()) return E_INVALIDARG;
    MONITORINFOEXW info{}; info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(list[index], &info)) return HRESULT_FROM_WIN32(GetLastError());
    output->id = reinterpret_cast<std::uint64_t>(list[index]); output->x = info.rcMonitor.left; output->y = info.rcMonitor.top;
    output->width = info.rcMonitor.right - info.rcMonitor.left; output->height = info.rcMonitor.bottom - info.rcMonitor.top;
    output->flags = (info.dwFlags & MONITORINFOF_PRIMARY) ? 1 : 0;
    WideCharToMultiByte(CP_UTF8, 0, info.szDevice, -1, output->title, sizeof(output->title), nullptr, nullptr); return S_OK;
}
extern "C" std::int32_t get_window_info(std::uint32_t index, CaptureTargetInfo* output) noexcept {
    if (!output) return E_INVALIDARG; *output = {}; auto list = windows(); if (index >= list.size()) return E_INVALIDARG;
    RECT rect{}; if (!GetWindowRect(list[index], &rect)) return HRESULT_FROM_WIN32(GetLastError());
    output->id = reinterpret_cast<std::uint64_t>(list[index]); output->x = rect.left; output->y = rect.top;
    output->width = rect.right - rect.left; output->height = rect.bottom - rect.top; output->flags = IsIconic(list[index]) ? 2 : 0;
    wchar_t wide[512]{}; GetWindowTextW(list[index], wide, static_cast<int>(std::size(wide)));
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, output->title, sizeof(output->title), nullptr, nullptr); return S_OK;
}
extern "C" std::int32_t capture_monitor(std::uint64_t id, CaptureBuffer* output) noexcept {
    if (!output) return E_INVALIDARG; *output = {};
    try { init_apartment(apartment_type::multi_threaded); ApartmentGuard guard;
        return capture_item(monitor_item(reinterpret_cast<HMONITOR>(id)), output);
    } catch (const hresult_error& e) { return e.code(); } catch (...) { return E_FAIL; }
}
extern "C" std::int32_t capture_window(std::uint64_t id, CaptureBuffer* output) noexcept {
    if (!output) return E_INVALIDARG; *output = {}; auto window = reinterpret_cast<HWND>(id);
    if (!IsWindow(window)) return E_INVALIDARG;
    if (IsIconic(window)) return HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
    try { init_apartment(apartment_type::multi_threaded); ApartmentGuard guard;
        return capture_item(window_item(window), output);
    } catch (const hresult_error& e) { return e.code(); } catch (...) { return E_FAIL; }
}
extern "C" std::int32_t capture_primary_monitor(CaptureBuffer* output) noexcept {
    return capture_monitor(reinterpret_cast<std::uint64_t>(MonitorFromPoint(POINT{0,0}, MONITOR_DEFAULTTOPRIMARY)), output);
}
extern "C" void free_capture_buffer(std::uint8_t* data) noexcept { delete[] data; }
