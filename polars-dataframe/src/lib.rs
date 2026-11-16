use pyo3::prelude::*;
use numpy::{PyArray1, PyReadonlyArray1};
use rayon::prelude::*;

#[pyfunction]
fn pack_bits_parallel(
    data: PyReadonlyArray1<i64>,
    bits_per_value: u8,
) -> PyResult<Py<PyArray1<u64>>> {
    let slice = data.as_slice()?;
    let num_elements = slice.len();

    if bits_per_value == 0 || bits_per_value > 64 {
        return Err(pyo3::exceptions::PyValueError::new_err(
            "bits_per_value must be between 1 and 64",
        ));
    }

    let total_bits = num_elements as u64 * bits_per_value as u64;
    let num_words = ((total_bits + 63) / 64) as usize;

    let chunk_size = 1000000;
    let num_chunks = (num_elements + chunk_size - 1) / chunk_size;

    let mut chunk_words = vec![0; num_chunks];
    for i in 0..num_chunks {
        let start_idx = i * chunk_size;
        let end_idx = std::cmp::min(start_idx + chunk_size, num_elements);
        let elements_in_chunk = end_idx - start_idx;
        let bits_in_chunk = elements_in_chunk as u64 * bits_per_value as u64;
        chunk_words[i] = ((bits_in_chunk + 63) / 64) as usize;
    }

    let mut chunk_word_offsets = vec![0; num_chunks];
    let mut current_offset = 0;
    for i in 0..num_chunks {
        chunk_word_offsets[i] = current_offset;
        current_offset += chunk_words[i];
    }

    let mut packed_words = vec![0u64; num_words];
    let packed_words_ptr = packed_words.as_mut_ptr() as usize;

    (0..num_chunks).into_par_iter().for_each(|chunk_idx| {
        let start_idx = chunk_idx * chunk_size;
        let end_idx = std::cmp::min(start_idx + chunk_size, num_elements);
        let word_offset = chunk_word_offsets[chunk_idx];

        let mut current_word = 0u64;
        let mut available_bits = 64;
        let mut local_word_idx = 0;

        let mask = if bits_per_value == 64 {
            u64::MAX
        } else {
            (1u64 << bits_per_value) - 1
        };

        let target_slice = unsafe {
            std::slice::from_raw_parts_mut(
                (packed_words_ptr as *mut u64).add(word_offset),
                chunk_words[chunk_idx],
            )
        };

        for idx in start_idx..end_idx {
            let val = slice[idx] as u64 & mask;

            if bits_per_value <= available_bits {
                current_word |= val << (64 - available_bits);
                available_bits -= bits_per_value;
            } else {
                let first_part_bits = available_bits;
                let second_part_bits = bits_per_value - available_bits;

                current_word |= val << (64 - first_part_bits);
                target_slice[local_word_idx] = current_word;
                local_word_idx += 1;

                current_word = val >> first_part_bits;
                available_bits = 64 - second_part_bits;
            }

            if available_bits == 0 {
                target_slice[local_word_idx] = current_word;
                local_word_idx += 1;
                current_word = 0;
                available_bits = 64;
            }
        }

        if available_bits < 64 && local_word_idx < target_slice.len() {
            target_slice[local_word_idx] = current_word;
        }
    });

    Python::with_gil(|py| {
        let array = PyArray1::from_vec(py, packed_words);
        Ok(array.to_owned())
    })
}

#[pymodule]
fn mechanicus_core(_py: Python<'_>, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(pack_bits_parallel, m)?)?;
    Ok(())
}
