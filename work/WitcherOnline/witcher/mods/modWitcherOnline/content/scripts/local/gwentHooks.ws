@wrapMethod(CR4GwintGameMenu)
function HandleOutgoingGwentAction( message : string )
{
    wrappedMethod(message);
    theGame.r_getMultiplayerClient().setLastGwentAction(message);
}

@wrapMethod(CR4GwintGameMenu)
function NotifyGwentMatchEnded( wonMatch : bool )
{
    wrappedMethod( wonMatch );
    if ( theGame.r_getMultiplayerClient().getInGwentGame() )
    {
        theGame.r_getMultiplayerClient().onGwentGameEnd( wonMatch );
    }
}
