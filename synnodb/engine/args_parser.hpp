#pragma once

// Increment file version to invalidate cache when this file is changed. This is needed because this file is included in the generated code and changes to it should trigger regeneration of all code that includes it.
// FILE_VERSION: 2

#include <iomanip>
#include <string>
#include <sstream>
#include <vector>

struct QueryRequest {
    std::string query_id; // query-id 
    std::string req_id; // id of the request
    std::string line; // line with query arguments
};

// Helper function to parse IN list from tuple syntax: ('val1', 'val2', ...)
// Necessary e.g. for CEB where some arguments are lists of values
inline std::vector<std::string> parse_in_list(std::istringstream& iss) {
    std::vector<std::string> result;

    // Read opening parenthesis
    char c;
    iss >> std::ws >> c;
    if (c != '(') {
        std::ostringstream oss;
        oss << "Expected '(' at start of IN list, but got '"
            << c << "' (int=" << static_cast<int>(static_cast<unsigned char>(c)) << ")";
        throw std::runtime_error(oss.str());
    }

    bool first = true;
    while (iss >> std::ws) {
        // Check for closing parenthesis
        if (iss.peek() == ')') {
            iss.get(); // consume ')'
            break;
        }

        // Skip comma after first element
        if (!first) {
            iss >> std::ws >> c;
            if (c != ',') {
                throw std::runtime_error("Expected ',' between IN list elements");
            }
        }
        first = false;

        std::string value;
        iss >> std::ws;
        if (iss.peek() == '\'') {
            iss.get();
            while (iss) {
                const char ch = static_cast<char>(iss.get());
                if (!iss) break;
                if (ch == '\'') {
                    if (iss.peek() == '\'') {
                        iss.get();
                        value.push_back('\'');
                        continue;
                    }
                    break;
                }
                value.push_back(ch);
            }
        } else {
            while (iss && iss.peek() != ',' && iss.peek() != ')') {
                value.push_back(static_cast<char>(iss.get()));
            }
            const auto start = value.find_first_not_of(" \t\r\n");
            const auto end = value.find_last_not_of(" \t\r\n");
            if (start == std::string::npos) {
                value.clear();
            } else {
                value = value.substr(start, end - start + 1);
            }
        }

        result.push_back(value);
    }

    return result;
}


//Q1
struct Q1Args {

};

inline Q1Args parse_q1(const QueryRequest& request) {
    Q1Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q2
struct Q2Args {

};

inline Q2Args parse_q2(const QueryRequest& request) {
    Q2Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q3
struct Q3Args {

};

inline Q3Args parse_q3(const QueryRequest& request) {
    Q3Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q4
struct Q4Args {

};

inline Q4Args parse_q4(const QueryRequest& request) {
    Q4Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q5
struct Q5Args {

};

inline Q5Args parse_q5(const QueryRequest& request) {
    Q5Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q6
struct Q6Args {

};

inline Q6Args parse_q6(const QueryRequest& request) {
    Q6Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q7
struct Q7Args {

};

inline Q7Args parse_q7(const QueryRequest& request) {
    Q7Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q8
struct Q8Args {

};

inline Q8Args parse_q8(const QueryRequest& request) {
    Q8Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q9
struct Q9Args {

};

inline Q9Args parse_q9(const QueryRequest& request) {
    Q9Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q10
struct Q10Args {

};

inline Q10Args parse_q10(const QueryRequest& request) {
    Q10Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q11
struct Q11Args {

};

inline Q11Args parse_q11(const QueryRequest& request) {
    Q11Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q12
struct Q12Args {

};

inline Q12Args parse_q12(const QueryRequest& request) {
    Q12Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q13
struct Q13Args {

};

inline Q13Args parse_q13(const QueryRequest& request) {
    Q13Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q14
struct Q14Args {

};

inline Q14Args parse_q14(const QueryRequest& request) {
    Q14Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q15
struct Q15Args {

};

inline Q15Args parse_q15(const QueryRequest& request) {
    Q15Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q16
struct Q16Args {

};

inline Q16Args parse_q16(const QueryRequest& request) {
    Q16Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q17
struct Q17Args {

};

inline Q17Args parse_q17(const QueryRequest& request) {
    Q17Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q19
struct Q19Args {

};

inline Q19Args parse_q19(const QueryRequest& request) {
    Q19Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q20
struct Q20Args {

};

inline Q20Args parse_q20(const QueryRequest& request) {
    Q20Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q21
struct Q21Args {

};

inline Q21Args parse_q21(const QueryRequest& request) {
    Q21Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q22
struct Q22Args {

};

inline Q22Args parse_q22(const QueryRequest& request) {
    Q22Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q23
struct Q23Args {

};

inline Q23Args parse_q23(const QueryRequest& request) {
    Q23Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q26
struct Q26Args {

};

inline Q26Args parse_q26(const QueryRequest& request) {
    Q26Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q28
struct Q28Args {

};

inline Q28Args parse_q28(const QueryRequest& request) {
    Q28Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q29
struct Q29Args {

};

inline Q29Args parse_q29(const QueryRequest& request) {
    Q29Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q30
struct Q30Args {

};

inline Q30Args parse_q30(const QueryRequest& request) {
    Q30Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q31
struct Q31Args {

};

inline Q31Args parse_q31(const QueryRequest& request) {
    Q31Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q32
struct Q32Args {

};

inline Q32Args parse_q32(const QueryRequest& request) {
    Q32Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q33
struct Q33Args {

};

inline Q33Args parse_q33(const QueryRequest& request) {
    Q33Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q34
struct Q34Args {

};

inline Q34Args parse_q34(const QueryRequest& request) {
    Q34Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q35
struct Q35Args {

};

inline Q35Args parse_q35(const QueryRequest& request) {
    Q35Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q36
struct Q36Args {

};

inline Q36Args parse_q36(const QueryRequest& request) {
    Q36Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q37
struct Q37Args {

};

inline Q37Args parse_q37(const QueryRequest& request) {
    Q37Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q38
struct Q38Args {

};

inline Q38Args parse_q38(const QueryRequest& request) {
    Q38Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q39
struct Q39Args {

};

inline Q39Args parse_q39(const QueryRequest& request) {
    Q39Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q40
struct Q40Args {

};

inline Q40Args parse_q40(const QueryRequest& request) {
    Q40Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q41
struct Q41Args {

};

inline Q41Args parse_q41(const QueryRequest& request) {
    Q41Args args;
    std::istringstream iss(request.line);



    return args;
}

//Q42
struct Q42Args {

};

inline Q42Args parse_q42(const QueryRequest& request) {
    Q42Args args;
    std::istringstream iss(request.line);



    return args;
}

