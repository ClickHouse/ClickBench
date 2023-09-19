import org.apache.spark.sql.{SparkSession, SQLContext}
import java.sql.Statement
import java.io.{FileOutputStream, File}
import scala.io.Source
import scala.io.Codec
import org.apache.spark.sql.types._

val spark = SparkSession.builder.enableHiveSupport().getOrCreate()
spark.sql("DROP TABLE IF EXISTS hits")
val logFile = "log.txt"
val fileOutputStream = new FileOutputStream(logFile)
val fileStream = new java.io.PrintStream(fileOutputStream, true, Codec.UTF8.toString)
System.setOut(fileStream)

val schema = StructType(
  List(
    StructField("WatchID", LongType, nullable = false),
    StructField("JavaEnable", ShortType, nullable = false),
    StructField("Title", StringType, nullable = false),
    StructField("GoodEvent", ShortType, nullable = false),
    StructField("EventTime", TimestampType, nullable = false),
    StructField("EventDate", DateType, nullable = false),
    StructField("CounterID", IntegerType, nullable = false),
    StructField("ClientIP", IntegerType, nullable = false),
    StructField("RegionID", IntegerType, nullable = false),
    StructField("UserID", LongType, nullable = false),
    StructField("CounterClass", ShortType, nullable = false),
    StructField("OS", ShortType, nullable = false),
    StructField("UserAgent", ShortType, nullable = false),
    StructField("URL", StringType, nullable = false),
    StructField("Referer", StringType, nullable = false),
    StructField("IsRefresh", ShortType, nullable = false),
    StructField("RefererCategoryID", ShortType, nullable = false),
    StructField("RefererRegionID", IntegerType, nullable = false),
    StructField("URLCategoryID", ShortType, nullable = false),
    StructField("URLRegionID", IntegerType, nullable = false),
    StructField("ResolutionWidth", ShortType, nullable = false),
    StructField("ResolutionHeight", ShortType, nullable = false),
    StructField("ResolutionDepth", ShortType, nullable = false),
    StructField("FlashMajor", ShortType, nullable = false),
    StructField("FlashMinor", ShortType, nullable = false),
    StructField("FlashMinor2", StringType, nullable = false),
    StructField("NetMajor", ShortType, nullable = false),
    StructField("NetMinor", ShortType, nullable = false),
    StructField("UserAgentMajor", ShortType, nullable = false),
    StructField("UserAgentMinor", StringType, nullable = false),
    StructField("CookieEnable", ShortType, nullable = false),
    StructField("JavascriptEnable", ShortType, nullable = false),
    StructField("IsMobile", ShortType, nullable = false),
    StructField("MobilePhone", ShortType, nullable = false),
    StructField("MobilePhoneModel", StringType, nullable = false),
    StructField("Params", StringType, nullable = false),
    StructField("IPNetworkID", IntegerType, nullable = false),
    StructField("TraficSourceID", ShortType, nullable = false),
    StructField("SearchEngineID", ShortType, nullable = false),
    StructField("SearchPhrase", StringType, nullable = false),
    StructField("AdvEngineID", ShortType, nullable = false),
    StructField("IsArtifical", ShortType, nullable = false),
    StructField("WindowClientWidth", ShortType, nullable = false),
    StructField("WindowClientHeight", ShortType, nullable = false),
    StructField("ClientTimeZone", ShortType, nullable = false),
    StructField("ClientEventTime", TimestampType, nullable = false),
    StructField("SilverlightVersion1", ShortType, nullable = false),
    StructField("SilverlightVersion2", ShortType, nullable = false),
    StructField("SilverlightVersion3", IntegerType, nullable = false),
    StructField("SilverlightVersion4", ShortType, nullable = false),
    StructField("PageCharset", StringType, nullable = false),
    StructField("CodeVersion", IntegerType, nullable = false),
    StructField("IsLink", ShortType, nullable = false),
    StructField("IsDownload", ShortType, nullable = false),
    StructField("IsNotBounce", ShortType, nullable = false),
    StructField("FUniqID", LongType, nullable = false),
    StructField("OriginalURL", StringType, nullable = false),
    StructField("HID", IntegerType, nullable = false),
    StructField("IsOldCounter", ShortType, nullable = false),
    StructField("IsEvent", ShortType, nullable = false),
    StructField("IsParameter", ShortType, nullable = false),
    StructField("DontCountHits", ShortType, nullable = false),
    StructField("WithHash", ShortType, nullable = false),
    StructField("HitColor", StringType, nullable = false),
    StructField("LocalEventTime", TimestampType, nullable = false),
    StructField("Age", ShortType, nullable = false),
    StructField("Sex", ShortType, nullable = false),
    StructField("Income", ShortType, nullable = false),
    StructField("Interests", ShortType, nullable = false),
    StructField("Robotness", ShortType, nullable = false),
    StructField("RemoteIP", IntegerType, nullable = false),
    StructField("WindowName", IntegerType, nullable = false),
    StructField("OpenerName", IntegerType, nullable = false),
    StructField("HistoryLength", ShortType, nullable = false),
    StructField("BrowserLanguage", StringType, nullable = false),
    StructField("BrowserCountry", StringType, nullable = false),
    StructField("SocialNetwork", StringType, nullable = false),
    StructField("SocialAction", StringType, nullable = false),
    StructField("HTTPError", ShortType, nullable = false),
    StructField("SendTiming", IntegerType, nullable = false),
    StructField("DNSTiming", IntegerType, nullable = false),
    StructField("ConnectTiming", IntegerType, nullable = false),
    StructField("ResponseStartTiming", IntegerType, nullable = false),
    StructField("ResponseEndTiming", IntegerType, nullable = false),
    StructField("FetchTiming", IntegerType, nullable = false),
    StructField("SocialSourceNetworkID", ShortType, nullable = false),
    StructField("SocialSourcePage", StringType, nullable = false),
    StructField("ParamPrice", LongType, nullable = false),
    StructField("ParamOrderID", StringType, nullable = false),
    StructField("ParamCurrency", StringType, nullable = false),
    StructField("ParamCurrencyID", ShortType, nullable = false),
    StructField("OpenstatServiceName", StringType, nullable = false),
    StructField("OpenstatCampaignID", StringType, nullable = false),
    StructField("OpenstatAdID", StringType, nullable = false),
    StructField("OpenstatSourceID", StringType, nullable = false),
    StructField("UTMSource", StringType, nullable = false),
    StructField("UTMMedium", StringType, nullable = false),
    StructField("UTMCampaign", StringType, nullable = false),
    StructField("UTMContent", StringType, nullable = false),
    StructField("UTMTerm", StringType, nullable = false),
    StructField("FromTag", StringType, nullable = false),
    StructField("HasGCLID", ShortType, nullable = false),
    StructField("RefererHash", LongType, nullable = false),
    StructField("URLHash", LongType, nullable = false),
    StructField("CLID", IntegerType, nullable = false))
)

val startTable = System.nanoTime()
val df = spark.read.schema(schema).option("header", "false").csv("/hits_neww.csv")
df.createOrReplaceTempView("hits")
val endTable = System.nanoTime()
val timeElapsedTable = (endTable - startTable) / 1000000
println(s"Creating table time: $timeElapsedTable ms")

val queries = Source.fromFile("queries.sql").getLines().toList
var itr: Int = 0
    queries.foreach(query => {
        val start = System.nanoTime()
        val result = spark.sql(query)
        val end = System.nanoTime()
        val timeElapsed = (end - start) / 1000000
        println(s"Query $itr | Time: $timeElapsed ms")
        itr += 1
    })


fileStream.close()
fileOutputStream.close()
spark.stop()
System.exit(0)
