fn main() {
    println!("cargo:rerun-if-changed=native/capture/capture_bridge.cpp");
    println!("cargo:rustc-link-lib=d3d11");
    println!("cargo:rustc-link-lib=dxgi");
    println!("cargo:rustc-link-lib=user32");
    println!("cargo:rustc-link-lib=comctl32");
    println!("cargo:rustc-link-lib=windowsapp");

    cc::Build::new()
        .cpp(true)
        .file("native/capture/capture_bridge.cpp")
        .flag_if_supported("/std:c++20")
        .flag_if_supported("/EHsc")
        .compile("capture_bridge");
}
