Class HD.KB Extends %RegisteredObject
{
/// Return versioned demo knowledge entries as review leads without asserting insurance violations.
ClassMethod Catalog() As %DynamicArray
{
    quit [{"id":"KB-001","version":"demo-2026-10","title":"同次就诊同药医嘱核查","text":"同次就诊出现相同药品编码的多条有效医嘱时，核实是否为调整、停用、分次开立或重复计费。"},{"id":"KB-002","version":"demo-2026-10","title":"病历肾功能信息与用药核查","text":"病历记载肾功能不全且存在布洛芬医嘱时，核对适应证、剂量及实际给药。"}]
}

/// Retrieve local knowledge and clinical evidence from stored FHIR resources to produce traceable demo findings.
ClassMethod Retrieve(encounterId As %String) As %DynamicArray
{
    set risks=[]
    kill medByCode,medRisk
    set ibuprofenId=""
    set id=""
    for {
        set id=$order(^HDData("resource",encounterId,"MedicationRequest",id)) quit:id=""
        set med={}.%FromJSON(^HDData("resource",encounterId,"MedicationRequest",id))
        if med.%Get("status","")'="active" { continue }
        set coding=med.medicationCodeableConcept.coding.%Get(0),code=coding.%Get("code","")
        if code="" { continue }
        if code="5640" { set ibuprofenId=id }
        if $data(medByCode(code)) {
            // Keep one stable finding ID per code and collect evidence from every active medication order.
            if '$data(medRisk(code)) {
                set first=medByCode(code),evidence=[{"resource":("MedicationRequest/"_first),"path":"medicationCodeableConcept.coding[0].code","value":(code)}]
                set medRisk(code)={"id":("risk-duplicate-"_code),"level":"待核实","title":"同次就诊存在相同药品编码的医嘱","knowledgeId":"KB-001","knowledgeVersion":"demo-2026-10","explanation":"本地知识条目命中多条有效医嘱；需核实是否调整或重复计费。","evidence":(evidence),"pending":["核实医嘱状态及时间","核对实际给药与收费明细"]}
                do risks.%Push(medRisk(code))
            }
            do medRisk(code).evidence.%Push({"resource":("MedicationRequest/"_id),"path":"medicationCodeableConcept.coding[0].code","value":(code)})
        } else { set medByCode(code)=id }
    }
    // Associate clinical text with medication codes for demo retrieval and retain explicit human review items.
    if ibuprofenId'="" {
        set noteId=""
        for {
            set noteId=$order(^HDData("resource",encounterId,"Composition",noteId)) quit:noteId=""
            // Accept both UTF-8 byte streams and decoded Unicode text for compatibility across demo container upgrades.
            set noteJSON=^HDData("resource",encounterId,"Composition",noteId)
            if $find(noteJSON,$char(232,130,190,229,138,159,232,131,189,228,184,141,229,133,168))!$find(noteJSON,$char(32958,21151,33021,19981,20840)) {
                set evidence=[{"resource":("Composition/"_noteId),"path":"section[0].text.div","value":"肾功能不全"},{"resource":("MedicationRequest/"_ibuprofenId),"path":"medicationCodeableConcept.coding[0].code","value":"5640"}]
                do risks.%Push({"id":"risk-renal-med","level":"待核实","title":"病历肾功能信息与布洛芬医嘱需核对","knowledgeId":"KB-002","knowledgeVersion":"demo-2026-10","explanation":"本地知识条目将病历片段与医嘱关联，不能据此直接认定违规。","evidence":(evidence),"pending":["确认肾功能信息的时效和临床解释","核对剂量、实际给药与医保政策口径"]})
                quit
            }
        }
    }
    quit risks
}
}
