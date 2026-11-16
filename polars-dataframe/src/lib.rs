use rayon::prelude::*;
use pyo3::prelude::*;
use pyo3::wrap_pyfunction;

// Der hocheffiziente AVX-512 Pfad für das AMD Zen 4 Blech (c7a.metal)
#[target_feature(enable = "avx512f,avx512bw,avx512dq")]
unsafe fn pack_column_avx512(data: &[i64]) -> Vec<u8> {
    // Hier liegt dein hochoptimierter Vektor-Assembly-Code
    // (Bleibt unverändert, wird aber nur auf c7a ausgeführt)
    let mut result = Vec::with_capacity(data.len()); 
    // ... dein bestehender AVX-Packing-Algorithmus ...
    result
}

// Der sichere Fallback-Pfad für ältere CPUs (Zen 3/c6a) und ARM (c8g)
fn pack_column_fallback(data: &[i64]) -> Vec<u8> {
    // Sicheres, paralleles Iterieren über Rayon, das überall kompiliert und läuft
    data.par_iter()
        .map(|&val| {
            // Standard-Bit-Shifting/Kompression ohne hardwarespezifische Register
            (val & 0xFF) as u8 // Beispielhaftes bit-safe Packing
        })
        .collect()
}

#[pyfunction]
fn pack_column(py: Python, data: Vec<i64>) -> PyResult<Vec<u8>> {
    // Erlaubt anderen Threads parallel zu laufen, während Rust rechnet
    py.allow_threads(|| {
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        {
            // Dynamische Prüfung der CPU-Features zur Laufzeit
            if is_x86_feature_detected!("avx512f") && is_x86_feature_detected!("avx512bw") {
                // Sicherer Aufruf der AVX-512 Funktion
                return Ok(unsafe { pack_column_avx512(&data) });
            }
        }
        
        // Wenn kein x86 oder kein AVX-512 vorhanden ist (z.B. c6a oder c8g ARM-Maschinen)
        Ok(pack_column_fallback(&data))
    })
}

#[pymodule]
fn mechanicus_core(_py: Python, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(pack_column, m)?)?;
    Ok(())
}
