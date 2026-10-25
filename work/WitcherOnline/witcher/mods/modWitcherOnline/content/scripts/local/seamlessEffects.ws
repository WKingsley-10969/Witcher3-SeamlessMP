// Experimental campaign primitives. These are deliberately restricted to test targets.
// They apply committed state; they do not execute/complete a quest graph.
// Fact SET normalizes the sum to one permanent fact record. It does not preserve history,
// expiry, telemetry, or FactsQuerySumSince/FactsQueryLatestValue semantics.
// Real quest facts enabled one at a time; must match FactDeltaTracker::IsVettedQuestFact.
// mh306_job_taken: taking the "Novigrad Hunt: Da'o" notice (native FactsAdd); the
// quest graph activates the journal entry from it. Probe run 20261024-203748.
function SC_IsVettedQuestFact(target : string) : bool
{
    return target == "mh306_job_taken";
}

function SC_IsFactTargetAllowed(target : string) : bool
{
    var i : int;
    var allowed : string;
    if(SC_IsVettedQuestFact(target))
    {
        return true;
    }
    if(StrLen(target) <= 8 || StrLen(target) > 96 || !StrBeginsWith(target, "sc_test_"))
    {
        return false;
    }
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    for(i = 0; i < StrLen(target); i += 1)
    {
        if(StrFindFirst(allowed, StrMid(target, i, 1)) < 0)
        {
            return false;
        }
    }
    return true;
}

function SC_IsJournalTargetAllowed(target : string) : bool
{
    return target == "sc_test_journal" || target == "sc_test_objective";
}

function SC_TestJournalName(target : string) : name
{
    if(target == "sc_test_journal")
    {
        return 'sc_test_journal';
    }
    if(target == "sc_test_objective")
    {
        return 'sc_test_objective';
    }
    return '';
}

function SC_IsJournalStatusValid(status : int) : bool
{
    return status == (int)JS_Inactive || status == (int)JS_Active
        || status == (int)JS_Success || status == (int)JS_Failed;
}

function SC_FindJournalEntry(target : string) : CJournalBase
{
    var manager : CWitcherJournalManager;
    var journalEntry : CJournalBase;
    var quests : array<CJournalBase>;
    var children : array<CJournalBase>;
    var grandchildren : array<CJournalBase>;
    var i, j, k : int;

    if(!SC_IsJournalTargetAllowed(target))
    {
        return NULL;
    }
    manager = theGame.GetJournalManager();
    if(!manager)
    {
        return NULL;
    }
    journalEntry = manager.GetEntryByTag(SC_TestJournalName(target));
    if(journalEntry && NameToString(journalEntry.GetUniqueScriptTag()) == target)
    {
        return journalEntry;
    }
    // The native tag lookup omits some inactive objectives. Walk only the known
    // activated quest hierarchy, without loading arbitrary resources from the wire.
    manager.GetActivatedOfType('CJournalQuest', quests);
    for(i = 0; i < quests.Size() && i < 2048; i += 1)
    {
        if(NameToString(quests[i].GetUniqueScriptTag()) == target)
        {
            return quests[i];
        }
        children.Clear();
        manager.GetAllChildren(quests[i], children);
        for(j = 0; j < children.Size() && j < 512; j += 1)
        {
            if(NameToString(children[j].GetUniqueScriptTag()) == target)
            {
                return children[j];
            }
            grandchildren.Clear();
            manager.GetAllChildren(children[j], grandchildren);
            for(k = 0; k < grandchildren.Size() && k < 512; k += 1)
            {
                if(NameToString(grandchildren[k].GetUniqueScriptTag()) == target)
                {
                    return grandchildren[k];
                }
            }
        }
    }
    return NULL;
}

function SC_JournalStatus(target : string) : int
{
    var journalEntry : CJournalBase;
    journalEntry = SC_FindJournalEntry(target);
    if(!journalEntry)
    {
        return -1;
    }
    return (int)theGame.GetJournalManager().GetEntryStatus(journalEntry);
}

function SC_CanApplyEffect(kind : string, target : string, value : int) : bool
{
    var journalEntry : CJournalBase;
    if(kind == "fact")
    {
        return SC_IsFactTargetAllowed(target);
    }
    if(kind == "journal")
    {
        if(!SC_IsJournalStatusValid(value))
        {
            return false;
        }
        journalEntry = SC_FindJournalEntry(target);
        if(!journalEntry)
        {
            return false;
        }
        return true;
    }
    return false;
}

function SC_ApplyFactAbsolute(target : string, value : int) : bool
{
    if(!SC_IsFactTargetAllowed(target))
    {
        return false;
    }
    // An existing zero fact and an absent fact are distinct. SET creates/preserves
    // existence; REMOVE below is the separate primitive. Replaying SET is harmless.
    if(!FactsDoesExist(target) || FactsQuerySum(target) != value)
    {
        FactsSet(target, value, -1);
    }
    return FactsDoesExist(target) && FactsQuerySum(target) == value;
}

// Applies a captured FactsSet. A positive validFor re-arms expiry from this game's
// current time; the original entry timestamp is not reproduced.
function SC_ApplyFactSet(target : string, value : int, validFor : int) : bool
{
    if(validFor == -1)
    {
        return SC_ApplyFactAbsolute(target, value);
    }
    if(!SC_IsFactTargetAllowed(target) || validFor < 1)
    {
        return false;
    }
    FactsSet(target, value, validFor);
    return FactsDoesExist(target) && FactsQuerySum(target) == value;
}

function SC_ApplyFactRemoval(target : string) : bool
{
    if(!SC_IsFactTargetAllowed(target))
    {
        return false;
    }
    if(FactsDoesExist(target))
    {
        FactsRemove(target);
    }
    return !FactsDoesExist(target);
}

function SC_ApplyJournalAbsolute(target : string, status : int) : bool
{
    var journalEntry : CJournalBase;
    var manager : CWitcherJournalManager;

    if(!SC_IsJournalStatusValid(status))
    {
        return false;
    }
    journalEntry = SC_FindJournalEntry(target);
    if(!journalEntry)
    {
        return false;
    }
    manager = theGame.GetJournalManager();
    if((int)manager.GetEntryStatus(journalEntry) != status)
    {
        // Do not implicitly activate parents or emit a second reward through a
        // synthetic quest graph. Cross-entry changes must be explicit transaction members.
        manager.ActivateEntry(journalEntry, (EJournalStatus)status, false, false);
    }
    return (int)manager.GetEntryStatus(journalEntry) == status;
}
