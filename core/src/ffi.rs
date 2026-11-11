//! Прямой FFI-слой над `libpdfium.dylib` (загружается через dlopen/libloading).
//!
//! Объявления строго по заголовкам `vendor/pdfium/fpdf*.h` (chrome/8152).
//! Никаких сторонних обёрток: только нужные символы, загружаются один раз
//! в статическую таблицу.

#![allow(non_snake_case)]
#![allow(non_camel_case_types)]
#![allow(non_upper_case_globals)]

use std::ffi::{c_char, c_int, c_ulong, c_void, CStr};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

pub type FPDF_DOCUMENT = *mut c_void;
pub type FPDF_PAGE = *mut c_void;
pub type FPDF_BITMAP = *mut c_void;
pub type FPDF_TEXTPAGE = *mut c_void;
pub type FPDF_SCHHANDLE = *mut c_void;
pub type FPDF_BOOKMARK = *mut c_void;
pub type FPDF_ACTION = *mut c_void;
pub type FPDF_DEST = *mut c_void;
pub type FPDF_STRUCTTREE = *mut c_void;
pub type FPDF_STRUCTELEMENT = *mut c_void;

pub type FPDF_BOOL = c_int;
pub type FPDF_DWORD = u32;
pub type FPDF_WIDESTRING = *const u16;
pub type FPDF_BYTESTRING = *const c_char;
pub type FPDF_STRING = *const c_char;

pub const FPDF_ANNOT: c_int = 0x01;
pub const FPDFBitmap_BGRA: c_int = 4;
pub const FPDF_MATCHCASE: c_ulong = 0x1;

// PDFium status codes (FPDF_ERR_*).
pub const FPDF_ERR_SUCCESS: c_ulong = 0;
pub const FPDF_ERR_UNKNOWN: c_ulong = 1;
pub const FPDF_ERR_FILE: c_ulong = 2;
pub const FPDF_ERR_FORMAT: c_ulong = 3;
pub const FPDF_ERR_PASSWORD: c_ulong = 4;
pub const FPDF_ERR_SECURITY: c_ulong = 5;
pub const FPDF_ERR_PAGE: c_ulong = 6;

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct FS_SIZEF {
    pub width: f32,
    pub height: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct FS_MATRIX {
    pub a: f32,
    pub b: f32,
    pub c: f32,
    pub d: f32,
    pub e: f32,
    pub f: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct FS_RECTF {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

macro_rules! declare_symbols {
    ($($name:ident : $ty:ty),+ $(,)?) => {
        #[allow(non_snake_case)]
        pub struct Pdfium {
            // Держим библиотеку живой: указатели на функции валидны, пока она загружена.
            _lib: libloading::Library,
            $(pub $name: $ty,)+
        }

        impl Pdfium {
            unsafe fn from_library(lib: libloading::Library) -> Result<Pdfium, String> {
                $(
                    let $name: $ty = {
                        let symbol = format!("{}\0", stringify!($name));
                        let sym = lib
                            .get::<$ty>(symbol.as_bytes())
                            .map_err(|e| format!("символ {}: {}", stringify!($name), e))?;
                        *sym
                    };
                )+
                Ok(Pdfium { _lib: lib, $($name,)+ })
            }
        }
    };
}

declare_symbols! {
    FPDF_InitLibrary: unsafe extern "C" fn(),
    FPDF_LoadDocument: unsafe extern "C" fn(FPDF_STRING, FPDF_BYTESTRING) -> FPDF_DOCUMENT,
    FPDF_CloseDocument: unsafe extern "C" fn(FPDF_DOCUMENT),
    FPDF_GetLastError: unsafe extern "C" fn() -> c_ulong,
    FPDF_GetPageCount: unsafe extern "C" fn(FPDF_DOCUMENT) -> c_int,
    FPDF_GetPageSizeByIndexF: unsafe extern "C" fn(FPDF_DOCUMENT, c_int, *mut FS_SIZEF) -> FPDF_BOOL,
    FPDF_LoadPage: unsafe extern "C" fn(FPDF_DOCUMENT, c_int) -> FPDF_PAGE,
    FPDF_ClosePage: unsafe extern "C" fn(FPDF_PAGE),
    FPDF_GetPageWidthF: unsafe extern "C" fn(FPDF_PAGE) -> f32,
    FPDF_GetPageHeightF: unsafe extern "C" fn(FPDF_PAGE) -> f32,
    FPDF_GetPageBoundingBox: unsafe extern "C" fn(FPDF_PAGE, *mut FS_RECTF) -> FPDF_BOOL,
    FPDFPage_GetRotation: unsafe extern "C" fn(FPDF_PAGE) -> c_int,
    FPDFBitmap_CreateEx: unsafe extern "C" fn(c_int, c_int, c_int, *mut c_void, c_int) -> FPDF_BITMAP,
    FPDFBitmap_Destroy: unsafe extern "C" fn(FPDF_BITMAP),
    FPDFBitmap_FillRect: unsafe extern "C" fn(FPDF_BITMAP, c_int, c_int, c_int, c_int, FPDF_DWORD) -> FPDF_BOOL,
    FPDFBitmap_GetBuffer: unsafe extern "C" fn(FPDF_BITMAP) -> *mut c_void,
    FPDFBitmap_GetStride: unsafe extern "C" fn(FPDF_BITMAP) -> c_int,
    FPDF_RenderPageBitmap: unsafe extern "C" fn(FPDF_BITMAP, FPDF_PAGE, c_int, c_int, c_int, c_int, c_int, c_int),
    FPDFText_LoadPage: unsafe extern "C" fn(FPDF_PAGE) -> FPDF_TEXTPAGE,
    FPDFText_ClosePage: unsafe extern "C" fn(FPDF_TEXTPAGE),
    FPDFText_CountChars: unsafe extern "C" fn(FPDF_TEXTPAGE) -> c_int,
    FPDFText_GetUnicode: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int) -> u32,
    FPDFText_GetCharBox: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int, *mut f64, *mut f64, *mut f64, *mut f64) -> FPDF_BOOL,
    FPDFText_GetCharOrigin: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int, *mut f64, *mut f64) -> FPDF_BOOL,
    FPDFText_GetFontSize: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int) -> f64,
    FPDFText_GetFontWeight: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int) -> c_int,
    FPDFText_GetFontInfo: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int, *mut c_void, c_ulong, *mut c_int) -> c_int,
    FPDFText_GetCharIndexAtPos: unsafe extern "C" fn(FPDF_TEXTPAGE, f64, f64, f64, f64) -> c_int,
    FPDFText_GetBoundedText: unsafe extern "C" fn(FPDF_TEXTPAGE, f64, f64, f64, f64, *mut u16, c_int) -> c_int,
    FPDFText_GetText: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int, c_int, *mut u16) -> c_int,
    FPDFText_CountRects: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int, c_int) -> c_int,
    FPDFText_GetRect: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int, *mut f64, *mut f64, *mut f64, *mut f64) -> FPDF_BOOL,
    FPDFText_IsGenerated: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int) -> c_int,
    FPDFText_GetCharAngle: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int) -> f32,
    FPDFText_GetMatrix: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int, *mut FS_MATRIX) -> FPDF_BOOL,
    FPDFText_IsHyphen: unsafe extern "C" fn(FPDF_TEXTPAGE, c_int) -> c_int,
    FPDFText_FindStart: unsafe extern "C" fn(FPDF_TEXTPAGE, FPDF_WIDESTRING, c_ulong, c_int) -> FPDF_SCHHANDLE,
    FPDFText_FindNext: unsafe extern "C" fn(FPDF_SCHHANDLE) -> FPDF_BOOL,
    FPDFText_FindClose: unsafe extern "C" fn(FPDF_SCHHANDLE),
    FPDFText_GetSchResultIndex: unsafe extern "C" fn(FPDF_SCHHANDLE) -> c_int,
    FPDFText_GetSchCount: unsafe extern "C" fn(FPDF_SCHHANDLE) -> c_int,
    FPDFBookmark_GetFirstChild: unsafe extern "C" fn(FPDF_DOCUMENT, FPDF_BOOKMARK) -> FPDF_BOOKMARK,
    FPDFBookmark_GetNextSibling: unsafe extern "C" fn(FPDF_DOCUMENT, FPDF_BOOKMARK) -> FPDF_BOOKMARK,
    FPDFBookmark_GetTitle: unsafe extern "C" fn(FPDF_BOOKMARK, *mut c_void, c_ulong) -> c_ulong,
    FPDFBookmark_GetDest: unsafe extern "C" fn(FPDF_DOCUMENT, FPDF_BOOKMARK) -> FPDF_DEST,
    FPDFBookmark_GetAction: unsafe extern "C" fn(FPDF_BOOKMARK) -> FPDF_ACTION,
    FPDFAction_GetDest: unsafe extern "C" fn(FPDF_DOCUMENT, FPDF_ACTION) -> FPDF_DEST,
    FPDFDest_GetDestPageIndex: unsafe extern "C" fn(FPDF_DOCUMENT, FPDF_DEST) -> c_int,
    FPDF_GetMetaText: unsafe extern "C" fn(FPDF_DOCUMENT, FPDF_BYTESTRING, *mut c_void, c_ulong) -> c_ulong,
    FPDF_StructTree_GetForPage: unsafe extern "C" fn(FPDF_PAGE) -> FPDF_STRUCTTREE,
    FPDF_StructTree_Close: unsafe extern "C" fn(FPDF_STRUCTTREE),
    FPDF_StructTree_CountChildren: unsafe extern "C" fn(FPDF_STRUCTTREE) -> c_int,
    FPDF_StructTree_GetChildAtIndex: unsafe extern "C" fn(FPDF_STRUCTTREE, c_int) -> FPDF_STRUCTELEMENT,
    FPDF_StructElement_GetType: unsafe extern "C" fn(FPDF_STRUCTELEMENT, *mut c_void, c_ulong) -> c_ulong,
    FPDF_StructElement_GetRawType: unsafe extern "C" fn(FPDF_STRUCTELEMENT, *mut c_void, c_ulong) -> c_ulong,
    FPDF_StructElement_GetTitle: unsafe extern "C" fn(FPDF_STRUCTELEMENT, *mut c_void, c_ulong) -> c_ulong,
    FPDF_StructElement_CountChildren: unsafe extern "C" fn(FPDF_STRUCTELEMENT) -> c_int,
    FPDF_StructElement_GetChildAtIndex: unsafe extern "C" fn(FPDF_STRUCTELEMENT, c_int) -> FPDF_STRUCTELEMENT,
}

/// Глобальный мьютекс: PDFium не потокобезопасен (кроме рендера в один поток).
pub static PDFIUM_LOCK: Mutex<()> = Mutex::new(());

impl Pdfium {
    /// UTF-16LE (с завершающим NUL, как отдаёт PDFium) → String.
    pub fn utf16le(bytes: &[u8]) -> String {
        let mut units = Vec::with_capacity(bytes.len() / 2);
        let mut i = 0;
        while i + 1 < bytes.len() {
            let u = u16::from_le_bytes([bytes[i], bytes[i + 1]]);
            if u == 0 {
                break;
            }
            units.push(u);
            i += 2;
        }
        String::from_utf16_lossy(&units)
    }

    /// Читает строковое свойство PDFium-объекта через двухфазный вызов
    /// (сначала длина буфера, затем сам буфер). `call` получает (buf, len_bytes).
    pub unsafe fn read_utf16(
        call: impl Fn(*mut c_void, c_ulong) -> c_ulong,
    ) -> String {
        let needed = call(std::ptr::null_mut(), 0);
        if needed == 0 {
            return String::new();
        }
        let mut buf = vec![0u8; needed as usize];
        let written = call(buf.as_mut_ptr() as *mut c_void, needed);
        if written == 0 {
            return String::new();
        }
        let n = (written as usize).min(buf.len());
        Self::utf16le(&buf[..n])
    }

    pub fn error_name(code: c_ulong) -> &'static str {
        match code {
            FPDF_ERR_SUCCESS => "OK",
            FPDF_ERR_FILE => "файл не найден или не открывается",
            FPDF_ERR_FORMAT => "файл повреждён или это не PDF",
            FPDF_ERR_PASSWORD => "требуется пароль",
            FPDF_ERR_SECURITY => "неподдерживаемая схема защиты",
            FPDF_ERR_PAGE => "страница не найдена / ошибка содержимого",
            _ => "неизвестная ошибка PDFium",
        }
    }
}

/// Загруженная таблица + залоченный глобальный мьютекс.
pub fn pdfium_locked() -> Result<(&'static Pdfium, std::sync::MutexGuard<'static, ()>), String> {
    let lib = pdfium()?;
    let guard = PDFIUM_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    Ok((lib, guard))
}

/// Доступ к загруженному PDFium (без блокировки). Обычно нужен `pdfium_locked`.
pub fn pdfium() -> Result<&'static Pdfium, String> {
    static CELL: OnceLock<Result<Pdfium, String>> = OnceLock::new();
    match CELL.get_or_init(load_pdfium) {
        Ok(p) => Ok(p),
        Err(e) => Err(e.clone()),
    }
}

fn load_pdfium() -> Result<Pdfium, String> {
    let mut tried: Vec<String> = Vec::new();
    for path in candidate_paths() {
        if !path.is_file() {
            continue;
        }
        match unsafe { libloading::Library::new(&path) } {
            Ok(lib) => match unsafe { Pdfium::from_library(lib) } {
                Ok(p) => {
                    unsafe { (p.FPDF_InitLibrary)() };
                    return Ok(p);
                }
                Err(e) => tried.push(format!("{}: {}", path.display(), e)),
            },
            Err(e) => tried.push(format!("{}: {}", path.display(), e)),
        }
    }
    Err(format!(
        "libpdfium.dylib не найдена (env PDFIUM_DYLIB / рядом с libpdfcore / vendor/pdfium / FOLIO_ROOT). Попытки: {}",
        if tried.is_empty() {
            "файл не найден ни по одному пути".to_string()
        } else {
            tried.join("; ")
        }
    ))
}

fn candidate_paths() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Ok(p) = std::env::var("PDFIUM_DYLIB") {
        out.push(PathBuf::from(p));
    }
    if let Some(own) = own_dylib_path() {
        if let Some(dir) = own.parent() {
            add_dir_candidates(&mut out, dir);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            add_dir_candidates(&mut out, dir);
        }
    }
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    add_dir_candidates(&mut out, manifest);
    add_dir_candidates(&mut out, &manifest.join(".."));
    add_dir_candidates(&mut out, &manifest.join("../.."));
    if let Ok(cwd) = std::env::current_dir() {
        let mut base: Option<&Path> = Some(cwd.as_path());
        let mut depth = 0;
        while let Some(dir) = base {
            if depth > 5 {
                break;
            }
            add_dir_candidates(&mut out, dir);
            base = dir.parent();
            depth += 1;
        }
    }
    if let Ok(root) = std::env::var("FOLIO_ROOT") {
        let root = PathBuf::from(root);
        add_dir_candidates(&mut out, &root);
        add_dir_candidates(&mut out, &root.join("pdfreader"));
    }
    out
}

fn add_dir_candidates(out: &mut Vec<PathBuf>, dir: &Path) {
    for rel in [
        "libpdfium.dylib",
        "vendor/pdfium/libpdfium.dylib",
        "core/vendor/pdfium/libpdfium.dylib",
        "pdfreader/core/vendor/pdfium/libpdfium.dylib",
        "../core/vendor/pdfium/libpdfium.dylib",
        "../vendor/pdfium/libpdfium.dylib",
        "target/release/libpdfium.dylib",
        "target/debug/libpdfium.dylib",
    ] {
        out.push(dir.join(rel));
    }
}

#[repr(C)]
struct DlInfo {
    dli_fname: *const c_char,
    dli_fbase: *mut c_void,
    dli_sname: *const c_char,
    dli_saddr: *mut c_void,
}

extern "C" {
    fn dladdr(addr: *const c_void, info: *mut DlInfo) -> c_int;
}

/// Путь к самой libpdfcore.dylib (если мы загружены как dylib) — чтобы найти
/// libpdfium.dylib рядом с собой.
fn own_dylib_path() -> Option<PathBuf> {
    let addr = Pdfium::from_library as *const () as *const c_void;
    let mut info = DlInfo {
        dli_fname: std::ptr::null(),
        dli_fbase: std::ptr::null_mut(),
        dli_sname: std::ptr::null(),
        dli_saddr: std::ptr::null_mut(),
    };
    let ok = unsafe { dladdr(addr, &mut info) };
    if ok == 0 || info.dli_fname.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(info.dli_fname) }
        .to_string_lossy()
        .into_owned();
    Some(PathBuf::from(s))
}
