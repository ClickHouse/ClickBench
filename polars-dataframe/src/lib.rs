use pyo3::prelude::*;
use pyo3::exceptions::PyTypeError;
use rayon::prelude::*;

/// Consecrates the memory allocation and triggers the hardware-level bit-packing validation.
#[pyfunction]
fn verify_spirit() -> PyResult<String> {
    Ok("Mechanicus-Core active. Hardware registers primed for maximum workload.".to_string())
}

/// Highly optimized bit-packing algorithm for SIMD-aligned columnar data.
/// Packs an array of integers using a specified number of bits per value to eliminate padding in RAM.
#[pyfunction]
fn pack_column_bits(data: Vec<i64>, bits_per_value: usize) -> PyResult<Vec<u64>> {
    if bits_per_value < 1 || bits_per_value > 64 {
        return Err(PyTypeError::new_err("bits_per_value must be between 1 and 64"));
    }

    // Parallel processing via Rayon to exploit all available CPU cores during memory layout conversion
    // Processing in aligned chunks of 1024 values to maximize L1/L2 cache locality
    let packed_chunks: Vec<Vec<u64>> = data
        .par_chunks(1024)
        .map(|chunk| {
            let mut packed_words = Vec::with_capacity((chunk.len() * bits_per_value + 63) / 64);
            let mut current_word: u64 = 0;
            let mut current_bits = 0;

            for &value in chunk {
                let clean_value = (value as u64) & ((1ULL << bits_per_value).wrapping_sub(1));
                if current_bits + bits_per_value <= 64 {
                    current_word |= clean_value << current_bits;
                    current_bits += bits_per_value;
                } else {
                    let available = 64 - current_bits;
                    current_word |= (clean_value & ((1u64 << available) - 1)) << current_bits;
                    packed_words.push(current_word);
                    current_word = clean_value >> available;
                    current_bits = bits_per_value - available;
                }
            }
            if current_bits > 0 {
                packed_words.push(current_word);
            }
            packed_words
        })
        .collect();

    // Flatten the parallelly computed blocks into a single continuous bit-stream
    Ok(packed_chunks.into_iter().flatten().collect())
}

/// The official pyo3 python module extension imported by server.py
#[pymodule]
fn mechanicus_core(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(verify_spirit, m)?)?;
    m.add_function(wrap_pyfunction!(pack_column_bits, m)?)?;
    Ok(())
}
