#include "query_impl.hpp"
#include "cpu_affinity.hpp"
#include "crash_handler.hpp"  // turn a run_qN SIGSEGV into a symbolized stack trace
#include "thread_pool.hpp"

// Increment file version to invalidate cache when this file is changed. This is needed because this file is included in the generated code and changes to it should trigger regeneration of all code that includes it.
// FILE_VERSION: 8


#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unistd.h>
#include <vector>
#include <cstdlib>

// ── Shared thread pool (get_query_pool) ───────────────────────────────────────
// Initialized once at program start; warm-up dispatches a no-op parallel_for
// so all worker threads are alive and spinning before the first query arrives.
ThreadPool& get_query_pool() {
    static struct Holder {
        ThreadPool pool;
        Holder() {
            init_thread_pool(pool);
            pool.parallel_for([](int, int) {});  // warm-up
        }
    } h;
    return h.pool;
}

#include "args_parser.hpp"
#include "result_writer.hpp"  // synnodb::write_result - exact Arrow egress
#include "query1.hpp"
#include "query2.hpp"
#include "query3.hpp"
#include "query4.hpp"
#include "query5.hpp"
#include "query6.hpp"
#include "query7.hpp"
#include "query8.hpp"
#include "query9.hpp"
#include "query10.hpp"
#include "query11.hpp"
#include "query12.hpp"
#include "query13.hpp"
#include "query14.hpp"
#include "query15.hpp"
#include "query16.hpp"
#include "query17.hpp"
#include "query19.hpp"
#include "query20.hpp"
#include "query21.hpp"
#include "query22.hpp"
#include "query23.hpp"
#include "query26.hpp"
#include "query28.hpp"
#include "query29.hpp"
#include "query30.hpp"
#include "query31.hpp"
#include "query32.hpp"
#include "query33.hpp"
#include "query34.hpp"
#include "query35.hpp"
#include "query36.hpp"
#include "query37.hpp"
#include "query38.hpp"
#include "query39.hpp"
#include "query40.hpp"
#include "query41.hpp"
#include "query42.hpp"



std::vector<QueryResult> query(Database* db, const std::vector<std::string>& query_lines) {
    // A fatal memory fault inside a run_qN escapes the per-query try/catch below and
    // kills the child; the handler prints the running query + a symbolized backtrace to
    // stderr (captured by the runner) so the failure is diagnosable, not just "signal 11".
    synnodb::install_crash_handler();

    std::vector<QueryResult> results;
    std::vector<QueryRequest> requests;
    for (const auto& line : query_lines) {
        std::istringstream iss(line);
        std::string query_id =  "0";
        iss >> query_id;
        std::string req_id = "0";
        iss >> req_id;
        if (!iss) {
            continue;
        }
        std::string args_line;
        std::getline(iss, args_line); // everything after inst_hash
        requests.push_back(QueryRequest{query_id, req_id, args_line});
    }

    (void)get_query_pool();

    // Call query implementations
    for (std::size_t i = 0; i < requests.size(); ++i) {
        const auto& req = requests[i];
        
        // TRACE_RESET();
        double elapsed_ms = -1;
        std::string error;
        const std::string prefix =
            "run #" + std::to_string(i + 1) + " Q" + req.query_id+"(" + req.req_id + "): ";
        // Tag the running query so a crash inside run_qN names it in the stack trace.
        synnodb::set_query_context(prefix.c_str());
        try {
            if (req.query_id == "1") {
                Q1Args args = parse_q1(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q1(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "2") {
                Q2Args args = parse_q2(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q2(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "3") {
                Q3Args args = parse_q3(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q3(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "4") {
                Q4Args args = parse_q4(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q4(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "5") {
                Q5Args args = parse_q5(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q5(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "6") {
                Q6Args args = parse_q6(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q6(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "7") {
                Q7Args args = parse_q7(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q7(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "8") {
                Q8Args args = parse_q8(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q8(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "9") {
                Q9Args args = parse_q9(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q9(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "10") {
                Q10Args args = parse_q10(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q10(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "11") {
                Q11Args args = parse_q11(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q11(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "12") {
                Q12Args args = parse_q12(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q12(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "13") {
                Q13Args args = parse_q13(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q13(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "14") {
                Q14Args args = parse_q14(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q14(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "15") {
                Q15Args args = parse_q15(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q15(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "16") {
                Q16Args args = parse_q16(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q16(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "17") {
                Q17Args args = parse_q17(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q17(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "19") {
                Q19Args args = parse_q19(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q19(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "20") {
                Q20Args args = parse_q20(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q20(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "21") {
                Q21Args args = parse_q21(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q21(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "22") {
                Q22Args args = parse_q22(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q22(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "23") {
                Q23Args args = parse_q23(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q23(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "26") {
                Q26Args args = parse_q26(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q26(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "28") {
                Q28Args args = parse_q28(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q28(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "29") {
                Q29Args args = parse_q29(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q29(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "30") {
                Q30Args args = parse_q30(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q30(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "31") {
                Q31Args args = parse_q31(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q31(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "32") {
                Q32Args args = parse_q32(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q32(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "33") {
                Q33Args args = parse_q33(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q33(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "34") {
                Q34Args args = parse_q34(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q34(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "35") {
                Q35Args args = parse_q35(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q35(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "36") {
                Q36Args args = parse_q36(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q36(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "37") {
                Q37Args args = parse_q37(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q37(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "38") {
                Q38Args args = parse_q38(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q38(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "39") {
                Q39Args args = parse_q39(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q39(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "40") {
                Q40Args args = parse_q40(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q40(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "41") {
                Q41Args args = parse_q41(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q41(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else if (req.query_id == "42") {
                Q42Args args = parse_q42(req);
                auto start = std::chrono::steady_clock::now();
                std::shared_ptr<arrow::Table> result = run_q42(db, args);
                auto end = std::chrono::steady_clock::now();
                elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
                synnodb::write_result(result, req.req_id);
            }
            else {
                throw std::runtime_error("Unsupported query id: " + req.query_id);
            }
        } catch (const std::exception& e) {
            error = prefix + e.what();
        } catch (...) {
            error = prefix + "unknown exception";
        }
        // TRACE_FLUSH();
        results.push_back(QueryResult{req.query_id, req.req_id, "", elapsed_ms, error});
    }
    return results;
}