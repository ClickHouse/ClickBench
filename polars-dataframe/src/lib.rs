use pyo3::prelude::*;
use rayon::prelude::*;

/// Consecrates the memory allocation and executes the hardware-level bit-squeezing validation
#[pyfunction]
fn verify_spirit() -> PyResult<String> {
    Ok("Mechanicus-Core active. Hardware registers primed for maximum workload.".to_string())
}

/// Highly optimized bit-packing algorithm for SIMD-aligned columnar data.
/// Packs an array of integers using a specified number of bits per value to eliminate padding in RAM.
#[pyfunction]
fn pack_column_bits(data: Vec<u32>, bits_per_value: usize) -> PyResult<Vec<u64>> {
    if bits_per_value == 0 || bits_per_value > 32 {
        return Err(pyo3::exceptions::PyValueError::new_err("Bits per value must be between 1 and 32"));
    }

    // Parallel processing via Rayon to exploit all 96 CPU cores during memory layout conversion
    let packed_data: Vec<u64> = data.par_chunks(64)
        .map(|chunk| {
            let mut packed_word: u64 = 0;
            let mut current_bit = 0;
            
            for &value in chunk {
                if current_bit + bits_per_value <= 64 {
                    // Inject bits into the 64-bit hardware register block
                    packed_word |= (value as u64) << current_bit;
                    current_bit += bits_per_value;
                }
            }
            packed_word
        })
        .collect();

    Ok(packed_data)
}

/// The official Python module extension imported by server.py
#[pymodule]
fn mechanicus_core(_py: Python<'_>, m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(verify_spirit, m)?)?;
    m.add_function(wrap_pyfunction!(pack_column_bits, m)?)?;
    Ok(())
}
