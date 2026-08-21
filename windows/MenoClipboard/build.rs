use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

const ICON_GROUP_ID: u16 = 101;
const MANIFEST_PATH: &str = "assets/MenoClipboard.manifest";
const AUDIO_DRIVER_ARCHIVE: &str = "VBCABLE_Driver_Pack45.zip";
const DRIVER_FILES: &[&str] = &[
    "MenoVirtualMouse.dll",
    "MenoVirtualMouse.inf",
    "MenoVirtualMouse.cat",
    "MenoVirtualMouse.cer",
];
const ICONS: &[(u8, &str)] = &[
    (16, "assets/MenoIcon-16.png"),
    (32, "assets/MenoIcon-32.png"),
    (64, "assets/MenoIcon-64.png"),
    (128, "assets/MenoIcon-128.png"),
    (0, "assets/MenoIcon-256.png"),
];

fn main() {
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=Cargo.toml");
    println!("cargo:rerun-if-changed={MANIFEST_PATH}");
    println!("cargo:rustc-env=MENO_BUILD_ID={}", build_id());
    for (_, path) in ICONS {
        println!("cargo:rerun-if-changed={path}");
    }
    let driver_directory = PathBuf::from("assets/driver");
    let driver_is_complete = DRIVER_FILES
        .iter()
        .all(|name| driver_directory.join(name).is_file());
    println!(
        "cargo:rustc-env=MENO_DRIVER_EMBEDDED={}",
        if driver_is_complete { "1" } else { "0" }
    );
    let output_directory = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is unavailable"));
    for name in DRIVER_FILES {
        let source = driver_directory.join(name);
        println!("cargo:rerun-if-changed={}", source.display());
        let bytes = fs::read(&source).unwrap_or_default();
        fs::write(output_directory.join(name), bytes)
            .expect("could not prepare embedded driver file");
    }

    let manifest_directory = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is unavailable"),
    );
    let audio_driver_archive = manifest_directory
        .parent()
        .expect("MenoClipboard must have a project parent")
        .join("third_party")
        .join("VB-CABLE")
        .join(AUDIO_DRIVER_ARCHIVE);
    println!("cargo:rerun-if-changed={}", audio_driver_archive.display());
    let audio_driver_bytes = fs::read(&audio_driver_archive).unwrap_or_default();
    println!(
        "cargo:rustc-env=MENO_AUDIO_DRIVER_EMBEDDED={}",
        if audio_driver_bytes.is_empty() {
            "0"
        } else {
            "1"
        }
    );
    fs::write(
        output_directory.join(AUDIO_DRIVER_ARCHIVE),
        audio_driver_bytes,
    )
    .expect("could not prepare embedded VB-CABLE archive");

    let mut resource = Vec::new();
    write_resource(&mut resource, 0, 0, &[]);

    let mut group = Vec::new();
    write_u16(&mut group, 0);
    write_u16(&mut group, 1);
    write_u16(&mut group, ICONS.len() as u16);

    for (index, (size, path)) in ICONS.iter().enumerate() {
        let image = fs::read(path).expect("could not read Windows icon image");
        let image_id = u16::try_from(index + 1).expect("too many icon images");
        write_resource(&mut resource, 3, image_id, &image);

        group.push(*size);
        group.push(*size);
        group.push(0);
        group.push(0);
        write_u16(&mut group, 1);
        write_u16(&mut group, 32);
        write_u32(&mut group, image.len() as u32);
        write_u16(&mut group, image_id);
    }

    write_resource(&mut resource, 14, ICON_GROUP_ID, &group);
    let manifest = fs::read(MANIFEST_PATH).expect("could not read Windows application manifest");
    write_resource(&mut resource, 24, 1, &manifest);
    let output = output_directory.join("MenoClipboard.res");
    fs::write(&output, resource).expect("could not write Windows icon resource");
    println!(
        "cargo:rustc-link-arg-bin=MenoClipboard={}",
        output.display()
    );
    println!("cargo:rustc-link-arg-bin=MenoHidProbe={}", output.display());
}

fn build_id() -> String {
    let version = env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "unknown".to_string());
    let Ok(head) = Command::new("git")
        .args(["rev-parse", "--short=12", "HEAD"])
        .output()
    else {
        return version;
    };
    if !head.status.success() {
        return version;
    }
    let head = String::from_utf8_lossy(&head.stdout).trim().to_string();
    if head.is_empty() {
        return version;
    }
    let dirty = Command::new("git")
        .args([
            "status",
            "--porcelain",
            "--untracked-files=normal",
            "--",
            ".",
        ])
        .output()
        .is_ok_and(|output| output.status.success() && !output.stdout.is_empty());
    if dirty { format!("{head}-dirty") } else { head }
}

fn write_resource(output: &mut Vec<u8>, resource_type: u16, name: u16, data: &[u8]) {
    let start = output.len();
    write_u32(output, data.len() as u32);
    write_u32(output, 0);
    write_numeric_identifier(output, resource_type);
    write_numeric_identifier(output, name);
    align_to_dword(output);
    write_u32(output, 0);
    write_u16(output, 0x0030);
    write_u16(output, 0);
    write_u32(output, 0);
    write_u32(output, 0);

    let header_size = (output.len() - start) as u32;
    output[start + 4..start + 8].copy_from_slice(&header_size.to_le_bytes());
    output.extend_from_slice(data);
    align_to_dword(output);
}

fn write_numeric_identifier(output: &mut Vec<u8>, value: u16) {
    write_u16(output, 0xFFFF);
    write_u16(output, value);
}

fn write_u16(output: &mut Vec<u8>, value: u16) {
    output.extend_from_slice(&value.to_le_bytes());
}

fn write_u32(output: &mut Vec<u8>, value: u32) {
    output.extend_from_slice(&value.to_le_bytes());
}

fn align_to_dword(output: &mut Vec<u8>) {
    while !output.len().is_multiple_of(4) {
        output.push(0);
    }
}
