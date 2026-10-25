// Narrow exact-operation observer. Disabled unless WO_SC_CAPTURE=1 AND a caller
// explicitly begins a test scope and watches sc_test_ targets. No native DB patch.
// This global replacement preserves the shipped 5.01 FactsSet body. It
// conflicts with another mod replacing FactsSet. No scene-helper/quest claim.
import function WNB_FactOpsReset() : int;
import function WNB_FactOpsActive() : bool;
import function WNB_FactOpsBegin(scope : string) : bool;
import function WNB_FactOpsWatch(target : string) : bool;
import function WNB_FactOpsEnd() : bool;
import function WNB_FactOpsBeginRemote() : bool;
import function WNB_FactOpsEndRemote() : bool;
import function WNB_FactOpsRecord(kind : string, target : string, value : int, validFor : int, telemetry : bool, observedAt : float) : bool;
import function WNB_FactOpsPeek() : string;
import function WNB_FactOpsAck(generation : int, revision : int) : bool;
import function WNB_FactOpsStatus() : string;

@replaceMethod
function FactsSet(ID : string, val : int, optional validFor : int)
{
    SC_ProbeFactsSet(ID);
    FactsRemove(ID);
    if(WNB_FactOpsActive()) WNB_FactOpsRecord("remove", ID, 0, 0, false, theGame.GetEngineTimeAsSeconds());
    if(validFor == 0)
        validFor = -1;
    FactsAdd(ID, val, validFor);
    if(WNB_FactOpsActive()) WNB_FactOpsRecord("add", ID, val, validFor, false, theGame.GetEngineTimeAsSeconds());
}
