use rayon::prelude::*;
use pyo3::prelude::*;
use pyo3::wrap_pyfunction;

// Highly efficient AVX-512 path for AMD Zen 4 hardware (c7a.metal)
// NOW PROTECTED: Ignored on ARM systems (like c8g) to prevent compilation errors
#[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
#[target_feature(enable = "avx512f,avx512bw,avx512dq")]
unsafe fn pack_column_avx512(data: &[i64]) -> Vec<u8> {
    let mut result = Vec::with_capacity(data.len());
    // ... your existing AVX packing algorithm ...
    // Note: If there is specific assembly/vector code here, it remains exactly as is.
    result
}

// Safe fallback path for older CPUs (Zen 3/c6a) and ARM (c8g)
fn pack_column_fallback(data: &[i64]) -> Vec<u8> {
    data.par_iter()
        .map(|&val| {
            // Standard bit-shifting/compression without hardware-specific vector registers
            (val & 0xFF) as u8
        })
        .collect()
}

#[pyfunction]
fn pack_column(py: Python, data: Vec<i64>) -> PyResult<Vec<u8>> {
    // Allows other threads to run in parallel while Rust is processing
    py.allow_threads(|| {
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            // Dynamic CPU feature check at runtime on x86 systems
            if is_x86_feature_detected!("avx512f") && is_x86_feature_detected!("avx512bw") {
                // Safe invocation of the AVX-512 function
                return Ok(unsafe { pack_column_avx512(&data) });
            }
        }
        
        // If not x86 or AVX-512 is unavailable (e.g., c6a or c8g ARM machines)
        Ok(pack_column_fallback(&data))
    })
}

#[pymodule]
fn mechanicus_core(_py: Python, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(pack_column, m)?)?;
    Ok(())
}
