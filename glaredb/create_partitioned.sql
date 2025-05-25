CREATE TEMP VIEW hits AS
  SELECT * REPLACE (
           EventDate::DATE            AS  EventDate,
           Title::TEXT                AS  Title,
           URL::TEXT                  AS  URL,
           Referer::TEXT              AS  Referer,
           FlashMinor2::TEXT          AS  FlashMinor2,
           UserAgentMinor::TEXT       AS  UserAgentMinor,
           MobilePhoneModel::TEXT     AS  MobilePhoneModel,
           Params::TEXT               AS  Params,
           SearchPhrase::TEXT         AS  SearchPhrase,
           PageCharset::TEXT          AS  PageCharset,
           OriginalURL::TEXT          AS  OriginalURL,
           HitColor::TEXT             AS  HitColor,
           BrowserLanguage::TEXT      AS  BrowserLanguage,
           BrowserCountry::TEXT       AS  BrowserCountry,
           SocialNetwork::TEXT        AS  SocialNetwork,
           SocialAction::TEXT         AS  SocialAction,
           SocialSourcePage::TEXT     AS  SocialSourcePage,
           ParamOrderID::TEXT         AS  ParamOrderID,
           ParamCurrency::TEXT        AS  ParamCurrency,
           OpenstatServiceName::TEXT  AS  OpenstatServiceName,
           OpenstatCampaignID::TEXT   AS  OpenstatCampaignID,
           OpenstatAdID::TEXT         AS  OpenstatAdID,
           OpenstatSourceID::TEXT     AS  OpenstatSourceID,
           UTMSource::TEXT            AS  UTMSource,
           UTMMedium::TEXT            AS  UTMMedium,
           UTMCampaign::TEXT          AS  UTMCampaign,
           UTMContent::TEXT           AS  UTMContent,
           UTMTerm::TEXT              AS  UTMTerm,
           FromTag::TEXT              AS  FromTag
           )
    FROM read_parquet('./data/hits_*.parquet')

