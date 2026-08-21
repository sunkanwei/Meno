use std::borrow::Cow;
use std::io::{self, Cursor, Write};

use arboard::ImageData;

use crate::protocol::MAX_IMAGE_SIZE;

pub const MAX_IMAGE_DIMENSION: usize = 16_384;
pub const MAX_RGBA_BYTES: usize = 64 * 1024 * 1024;
const MAX_DECODE_PEAK_BYTES: usize = 128 * 1024 * 1024;
const MAX_DECODER_INTERNAL_BYTES: usize = 64 * 1024 * 1024;

pub fn encode_png(image: ImageData<'_>) -> Result<Vec<u8>, String> {
    let rgba_bytes = checked_rgba_bytes(image.width, image.height)?;
    if image.bytes.len() != rgba_bytes {
        return Err("image RGBA buffer length does not match its dimensions".to_string());
    }
    let width = u32::try_from(image.width).map_err(|_| "image width is too large")?;
    let height = u32::try_from(image.height).map_err(|_| "image height is too large")?;
    let mut output = LimitedWriter::new(MAX_IMAGE_SIZE);
    {
        let mut encoder = png::Encoder::new(&mut output, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder.write_header().map_err(|error| error.to_string())?;
        writer
            .write_image_data(image.bytes.as_ref())
            .map_err(|error| error.to_string())?;
    }
    Ok(output.finish())
}

pub fn decode_png(data: &[u8]) -> Result<ImageData<'static>, String> {
    if data.len() > MAX_IMAGE_SIZE {
        return Err("PNG payload exceeds the compressed-size limit".to_string());
    }
    let mut decoder = png::Decoder::new_with_limits(
        Cursor::new(data),
        png::Limits {
            bytes: MAX_DECODER_INTERNAL_BYTES,
        },
    );
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().map_err(|error| error.to_string())?;
    let width = usize::try_from(reader.info().width)
        .map_err(|_| "decoded image width is too large".to_string())?;
    let height = usize::try_from(reader.info().height)
        .map_err(|_| "decoded image height is too large".to_string())?;
    let rgba_bytes = checked_rgba_bytes(width, height)?;
    let size = reader
        .output_buffer_size()
        .ok_or_else(|| "decoded image is too large".to_string())?;
    if size > MAX_RGBA_BYTES
        || size
            .checked_add(rgba_bytes)
            .is_none_or(|peak| peak > MAX_DECODE_PEAK_BYTES)
    {
        return Err("decoded image exceeds the memory budget".to_string());
    }
    let mut source = allocate_zeroed(size)?;
    let info = reader
        .next_frame(&mut source)
        .map_err(|error| error.to_string())?;
    if usize::try_from(info.width).ok() != Some(width)
        || usize::try_from(info.height).ok() != Some(height)
        || info.buffer_size() > source.len()
    {
        return Err("decoded image metadata changed unexpectedly".to_string());
    }
    source.truncate(info.buffer_size());
    if info.color_type == png::ColorType::Rgba {
        if source.len() != rgba_bytes {
            return Err("decoded RGBA length does not match its dimensions".to_string());
        }
        return Ok(ImageData {
            width,
            height,
            bytes: Cow::Owned(source),
        });
    }

    let pixels = source.as_slice();
    let mut rgba = Vec::new();
    rgba.try_reserve_exact(rgba_bytes)
        .map_err(|_| "decoded image allocation failed".to_string())?;
    match info.color_type {
        png::ColorType::Rgb => {
            for pixel in pixels.chunks_exact(3) {
                rgba.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]);
            }
        }
        png::ColorType::Grayscale => {
            for value in pixels {
                rgba.extend_from_slice(&[*value, *value, *value, 255]);
            }
        }
        png::ColorType::GrayscaleAlpha => {
            for pixel in pixels.chunks_exact(2) {
                rgba.extend_from_slice(&[pixel[0], pixel[0], pixel[0], pixel[1]]);
            }
        }
        png::ColorType::Indexed => return Err("indexed PNG was not expanded".to_string()),
        png::ColorType::Rgba => unreachable!(),
    }
    if rgba.len() != rgba_bytes {
        return Err("decoded pixel length does not match its dimensions".to_string());
    }
    Ok(ImageData {
        width,
        height,
        bytes: Cow::Owned(rgba),
    })
}

pub fn checked_rgba_bytes(width: usize, height: usize) -> Result<usize, String> {
    if width == 0 || height == 0 {
        return Err("image dimensions must be non-zero".to_string());
    }
    if width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION {
        return Err(format!(
            "image dimensions exceed the {MAX_IMAGE_DIMENSION} pixel limit"
        ));
    }
    let bytes = width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or_else(|| "image dimensions overflow the RGBA size".to_string())?;
    if bytes > MAX_RGBA_BYTES {
        return Err(format!(
            "image RGBA data exceeds the {MAX_RGBA_BYTES} byte limit"
        ));
    }
    Ok(bytes)
}

fn allocate_zeroed(size: usize) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(size)
        .map_err(|_| "decoded image allocation failed".to_string())?;
    bytes.resize(size, 0);
    Ok(bytes)
}

struct LimitedWriter {
    bytes: Vec<u8>,
    limit: usize,
}

impl LimitedWriter {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
        }
    }

    fn finish(self) -> Vec<u8> {
        self.bytes
    }
}

impl Write for LimitedWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let length = self
            .bytes
            .len()
            .checked_add(buffer.len())
            .ok_or_else(|| io::Error::other("PNG output length overflow"))?;
        if length > self.limit {
            return Err(io::Error::other("encoded PNG exceeds the size limit"));
        }
        self.bytes
            .try_reserve_exact(buffer.len())
            .map_err(|_| io::Error::other("PNG output allocation failed"))?;
        self.bytes.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
