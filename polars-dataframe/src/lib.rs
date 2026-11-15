use pyo3::prelude::*;
use pyo3::exceptions::PyTypeError;
use numpy::PyArray1;
use rayon::prelude::*;

#[pyfunction]
fn verify_spirit() -> PyResult<String> {
    Ok("Mechanicus-Core active. Hardware registers primed for maximum workload.".to_string())
}

#[pyfunction]
fn pack_column_bits(data: &Bound<'_, PyArray1<i64>>, bits_per_value: usize) -> PyResult<Vec<u64>> {
    if bits_per_value < 1 || bits_per_value > 64 {
        return Err(PyTypeError::new_err("bits_per_value must be between 1 and 64"));
    }

    // Safely access the continuous memory space using numpy zero-copy read view
    let readonly_array = data.readonly();
    let view = readonly_array.as_slice()?;

    let packed_chunks: Vec<Vec<u64>> = view
        .par_chunks(1024)
        .map(|chunk| {
            let mut packed_words = Vec::with_capacity((chunk.len() * bits_per_value + 63) / 64);
            let mut current_word: u64 = 0;
            let mut current_bits = 0;
            let mask = if bits_per_value == 64 { u64::MAX } else { u64::MAX >> (64 - bits_per_value) };

            for &value in chunk {
                let clean_value = (value as u64) & mask;
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

    Ok(packed_chunks.into_iter().flatten().collect())
}

#[pymodule]
fn mechanicus_core(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(verify_spirit, m)?)?;
    m.add_function(wrap_pyfunction!(pack_column_bits, m)?)?;
    Ok(())
}
