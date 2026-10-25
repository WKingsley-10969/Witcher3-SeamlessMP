// Remastered can load the player figures without registering the legacy DLC's
// fake menu items. Use the game's normal confirmation UI when those items are
// unavailable, instead of opening an empty ItemSelectionPopup.
function WO_IsPartyPrompt(id : int) : bool
{
    return id > 1880000000 && id <= 1881000000;
}

class r_CoopPartyPrompt
{
    private var serial : int;
    private var activeId : int;
    private var target : string;
    private var oldParty : string;
    private var leaving : bool;
    private var expires : float;

    public function GetActiveId() : int { return activeId; }

    public function Open(client : r_MultiplayerClient, player : r_RemotePlayer)
    {
        var previous : int;
        var title, text : string;
        previous = activeId;
        activeId = 0;
        if(previous != 0) { theGame.GetGuiManager().HideUserDialog(previous); }
        if(!player || player.username == "" || player.username == client.getUsername()) { return; }
        if(serial >= 1000000) { theGame.GetGuiManager().ShowNotification("Party menu needs a game restart."); return; }
        serial += 1;
        activeId = 1880000000 + serial;
        target = player.username;
        leaving = client.getInParty();
        oldParty = client.getJoinedParty();
        expires = theGame.GetEngineTimeAsSeconds() + 60.0;
        title = "Join party";
        text = "Join " + target + "'s party?";
        if(leaving)
        {
            title = "Leave party";
            text = "Leave your current party?";
        }
        // Publish all prompt state before showing it: callbacks may be immediate.
        theGame.GetGuiManager().ShowUserDialogAdv(activeId, title, text, false, UDB_YesNo);
    }

    public function Answer(client : r_MultiplayerClient, id : int, action : EUserMessageAction)
    {
        var player : r_RemotePlayer;
        var playerName : string;
        var leave : bool;
        if(id != activeId) { return; }
        activeId = 0; // A repeated callback cannot perform another action.
        playerName = target;
        leave = leaving;
        target = "";
        if(action != UMA_Yes) { return; }
        if(theGame.GetEngineTimeAsSeconds() > expires || client.getInParty() != leave
            || client.getJoinedParty() != oldParty)
        {
            theGame.GetGuiManager().ShowNotification("Party changed. Interact with the player again.");
            return;
        }
        if(leave) { client.leaveParty(); return; }
        player = mpghosts_getPlayer(playerName);
        if(!player || !player.ghost)
        {
            theGame.GetGuiManager().ShowNotification("That player is no longer nearby. Interact with them again.");
            return;
        }
        client.joinParty(playerName);
    }
}

@addField(r_MultiplayerClient)
var wo_partyPrompt : r_CoopPartyPrompt;

@addMethod(r_MultiplayerClient)
public function GetPartyPrompt() : r_CoopPartyPrompt
{
    if(!wo_partyPrompt) { wo_partyPrompt = new r_CoopPartyPrompt in this; }
    return wo_partyPrompt;
}

@wrapMethod(r_MultiplayerClient)
function createMenu(actor : CActor)
{
    var player : r_RemotePlayer;
    var category : name;
    category = theGame.GetDefinitionsManager().GetItemCategory('wo_joinParty');
    if(category == '' || category == 'None')
    {
        player = mpghosts_getPlayerFromActor(actor);
        if(player) { GetPartyPrompt().Open(this, player); }
        return;
    }
    wrappedMethod(actor);
}

@wrapMethod(CR4GuiManager)
function UserDialogCallback(messageId : int, actionId : EUserMessageAction) : void
{
    if(WO_IsPartyPrompt(messageId))
    {
        theGame.r_getMultiplayerClient().GetPartyPrompt().Answer(theGame.r_getMultiplayerClient(), messageId, actionId);
        return;
    }
    wrappedMethod(messageId, actionId);
}
