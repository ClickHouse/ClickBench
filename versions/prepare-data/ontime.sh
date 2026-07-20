#!/usr/bin/env bash
# Prepare ontime.native - the airline on-time performance dataset (single table),
# from the saved copy in the public bucket (ClickHouse docs "Import from a saved
# copy"). The full CSV has 109 columns but the query set touches only 12, so we
# read the full schema (LowCardinality(String) -> String, the only oldest-
# incompatible type) and project just those. FlightDate (a real Date) serves the
# legacy MergeTree engine, so no synth_date is needed.
#
# The output is sorted by (Year, Month, FlightDate, ...): the data spans
# 1987-2024 (~450 monthly partitions), so an unsorted INSERT block would touch
# >100 partitions at once and hit max_partitions_per_insert_block. Sorting makes
# each block date-contiguous (a few months), so it loads on every version.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
OUT="${HERE}/data/ontime.native.zst"
SRC="https://clickhouse-public-datasets.s3.amazonaws.com/ontime/csv_by_year/*.csv.gz"
command -v "${CLICKHOUSE}" >/dev/null 2>&1 || CLICKHOUSE=clickhouse

FULL_STRUCT="Year UInt16, Quarter UInt8, Month UInt8, DayofMonth UInt8, DayOfWeek UInt8, FlightDate Date, Reporting_Airline String, DOT_ID_Reporting_Airline Int32, IATA_CODE_Reporting_Airline String, Tail_Number String, Flight_Number_Reporting_Airline String, OriginAirportID Int32, OriginAirportSeqID Int32, OriginCityMarketID Int32, Origin FixedString(5), OriginCityName String, OriginState FixedString(2), OriginStateFips FixedString(2), OriginStateName String, OriginWac Int32, DestAirportID Int32, DestAirportSeqID Int32, DestCityMarketID Int32, Dest FixedString(5), DestCityName String, DestState FixedString(2), DestStateFips FixedString(2), DestStateName String, DestWac Int32, CRSDepTime Int32, DepTime Int32, DepDelay Int32, DepDelayMinutes Int32, DepDel15 Int32, DepartureDelayGroups String, DepTimeBlk String, TaxiOut Int32, WheelsOff String, WheelsOn String, TaxiIn Int32, CRSArrTime Int32, ArrTime Int32, ArrDelay Int32, ArrDelayMinutes Int32, ArrDel15 Int32, ArrivalDelayGroups String, ArrTimeBlk String, Cancelled Int8, CancellationCode FixedString(1), Diverted Int8, CRSElapsedTime Int32, ActualElapsedTime Int32, AirTime Int32, Flights Int32, Distance Int32, DistanceGroup Int8, CarrierDelay Int32, WeatherDelay Int32, NASDelay Int32, SecurityDelay Int32, LateAircraftDelay Int32, FirstDepTime Int16, TotalAddGTime Int16, LongestAddGTime Int16, DivAirportLandings Int8, DivReachedDest Int8, DivActualElapsedTime Int16, DivArrDelay Int16, DivDistance Int16, Div1Airport String, Div1AirportID Int32, Div1AirportSeqID Int32, Div1WheelsOn Int16, Div1TotalGTime Int16, Div1LongestGTime Int16, Div1WheelsOff Int16, Div1TailNum String, Div2Airport String, Div2AirportID Int32, Div2AirportSeqID Int32, Div2WheelsOn Int16, Div2TotalGTime Int16, Div2LongestGTime Int16, Div2WheelsOff Int16, Div2TailNum String, Div3Airport String, Div3AirportID Int32, Div3AirportSeqID Int32, Div3WheelsOn Int16, Div3TotalGTime Int16, Div3LongestGTime Int16, Div3WheelsOff Int16, Div3TailNum String, Div4Airport String, Div4AirportID Int32, Div4AirportSeqID Int32, Div4WheelsOn Int16, Div4TotalGTime Int16, Div4LongestGTime Int16, Div4WheelsOff Int16, Div4TailNum String, Div5Airport String, Div5AirportID Int32, Div5AirportSeqID Int32, Div5WheelsOn Int16, Div5TotalGTime Int16, Div5LongestGTime Int16, Div5WheelsOff Int16, Div5TailNum String"

echo "ontime: building from ${SRC} -> ${OUT}"
"${CLICKHOUSE}" local --max_memory_usage 0 --max_bytes_before_external_sort 30000000000 \
    --input_format_csv_empty_as_default 1 \
    --query "SELECT Year, Month, DayOfWeek, FlightDate, IATA_CODE_Reporting_Airline, Origin, OriginCityName, OriginState, DestCityName, DestState, DepDelay, ArrDelayMinutes FROM s3('${SRC}', 'CSVWithNames', '${FULL_STRUCT}') ORDER BY Year, Month, FlightDate, IATA_CODE_Reporting_Airline FORMAT Native" \
    | zstd -q -6 -T0 -c > "${OUT}"
ls -l "${OUT}"
