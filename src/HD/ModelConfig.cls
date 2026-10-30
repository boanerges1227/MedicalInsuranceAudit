Class HD.ModelConfig Extends %RegisteredObject
{
/// Build configuration names using the medical audit project's isolated namespace.
ClassMethod BaseName() As %String { quit "AI.LLM.HDReview"_$namespace }
/// Read the active configuration without accepting arbitrary configuration names from request parameters.
ClassMethod Name() As %String
{
    set id=$get(^HDModels($namespace,"active"),"default")
    if id="default" { quit ..BaseName() }
    if (id'?1"p"1.N)!('$data(^HDModels($namespace,"profiles",id))) { throw ##class(%Exception.General).%New("MODEL_PROFILE_NOT_FOUND") }
    quit ..BaseName()_"_"_id
}
/// Store isolated project credentials in IRIS Wallet; never print, log, or return keys.
ClassMethod Install(config As %DynamicObject)
{
    set model=config.%Get("model",""),base=config.%Get("base_url",""),key=config.%Get("api_key","")
    if (model="")!(base="")!(key="") { throw ##class(%Exception.General).%New("MODEL_CONFIG_INVALID") }
    new $namespace set $namespace="%SYS"
    set sc=##class(%ConfigStore.DescriptorManager).RebuildRegistry()
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_FAILED") }
    for res="HDModelUse","HDModelEdit","HDConfigRead","HDConfigEdit" {
        if '##class(Security.Resources).Exists(res) { set sc=##class(Security.Resources).Create(res,"Medical audit model","",0) if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_FAILED") } }
    }
    if '##class(%Wallet.Collection).Exists("HDReviewUSER") {
        set sc=##class(%Wallet.Collection).Create("HDReviewUSER",{"UseResource":"HDModelUse","EditResource":"HDModelEdit"})
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_FAILED") }
    }
    if '##class(%Wallet.KeyValue).Exists("HDReviewUSER.Model") {
        set sc=##class(%Wallet.KeyValue).Create("HDReviewUSER.Model",{"Usage":"CUSTOM","Secret":{"api_key":(key)}})
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_FAILED") }
    }
    if '##class(%ConfigStore.Configuration).Exists("AI.LLM.HDReviewUSER") {
        set details={"model_provider":"openai","model":(model),"base_url":(base),"api_key":"secret://HDReviewUSER.Model#api_key"}
        set sc=##class(%ConfigStore.Configuration).Create("AI","LLM","","HDReviewUSER",details,"Medical audit model","Synthetic demo","HDConfigRead:U","HDConfigEdit:U")
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_FAILED") }
    }
}

/// Use the medical audit project's isolated ConfigStore configuration; resolve credentials through IRIS Wallet only.
ClassMethod Provider(Output model As %String, name As %String = "") As %AI.Provider
{
    try {
        if name="" { set name=..Name() }
        set sc=##class(%ConfigStore.Configuration).Get(name,.cfg)
        if $system.Status.IsError(sc)!('cfg.Enabled) { throw ##class(%Exception.General).%New("MODEL_NOT_CONFIGURED") }
        set sc=##class(%ConfigStore.Configuration).GetDetails(name,.config,1,1)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_NOT_CONFIGURED") }
        set model=config.%Get("model",""),base=config.%Get("base_url",""),key=config.%Get("api_key","")
        if (model="")!(base="")!(key="") { throw ##class(%Exception.General).%New("MODEL_NOT_CONFIGURED") }
        set adapter=config.%Get("model_provider","openai"),client={"api_key":(key),"http_config":{"request_timeout_secs":60,"connect_timeout_secs":10}}
        if adapter="openai" { set client."base_url"=base }
        return ##class(%AI.Provider).Create(adapter,client)
    } catch ex { throw ##class(%Exception.General).%New("MODEL_NOT_CONFIGURED") }
}
}
