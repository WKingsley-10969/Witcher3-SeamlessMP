state MP_Render in MP_SUOL_Manager {
	event OnEnterState(previous_state_name: name) {
		super.OnEnterState(previous_state_name);
		MP_SUOL_Logger("Entering state [Render]");

		this.Render_main();
	}

	entry function Render_main() {
		this.renderingLoop();

		parent.GotoState('MP_SUOL_Idle');
	}

	latent function renderingLoop() {
		var sprite: CScriptedFlashSprite;
		var oneliner: MP_SU_Oneliner;
		var oneliners_count: int;
		var i: int;

		var player_position: Vector;
		var screen_position: Vector;
		var in_scene: bool;
		screen_position = thePlayer.GetWorldPosition();
		player_position = thePlayer.GetWorldPosition();

		while (true) {
			oneliners_count = parent.oneliners.Size();

			if (oneliners_count <= 0) {
				break;
			}

			player_position = thePlayer.GetWorldPosition();
			in_scene = MP_SUOL_hiddenForScene();

			for (i = 0; i < oneliners_count; i += 1) {
				oneliner = parent.oneliners[i];
				sprite = parent.module_flash.GetChildFlashSprite("mcOneliner" + oneliner.id);

				if (in_scene || !oneliner.getVisible(player_position)) {
					sprite.SetVisible(false);
					continue;	
				}

				if (oneliner.getScreenPosition(parent.module_hud, screen_position)) {
					sprite.SetPosition(screen_position.X, screen_position.Y);
					sprite.SetAlpha(100.0);
					sprite.SetVisible(true);
				} else {
					sprite.SetVisible(false);
				}
			}

			SleepOneFrame();
		}
	}
}

/// Labels (player names, statuses) are hidden during dialogue and cutscenes, like the players'
/// figures (client.ws), so they do not cover the subtitles; the same setting shows both.
function MP_SUOL_hiddenForScene(): bool {
	return theGame.IsDialogOrCutscenePlaying() && !theGame.GetInGameConfigWrapper().GetVarValue('MPGhosts_Main', 'MPGhosts_ShowInCutscene');
}

/// The function returns true if the position in visible on the screen, false if
/// it is not.
function MP_SUOL_worldToScreenPosition(hud: CR4ScriptedHud, world_position: Vector, out screen_position: Vector): bool {
	if (!theCamera.WorldVectorToViewRatio(world_position, screen_position.X, screen_position.Y)) {
		return false;
	}

	screen_position.X = (screen_position.X + 1) / 2;
	screen_position.Y = (screen_position.Y + 1) / 2;

	// at this point, screen_position is a normalized [0;1] vector, the GetScale
	// function transforms it into non normlized screen coordinates:
	screen_position = hud.GetScaleformPoint(screen_position.X, screen_position.Y);

	return true;
}

/// The render loop above does not run while a scene plays, so labels stayed as last drawn, over
/// the subtitles. The game's HUD ticks its one-liners module every frame, scenes included: hide
/// the labels there.
@wrapMethod(CR4HudModuleOneliners)
function OnTick(timeDelta: float) {
	wrappedMethod(timeDelta);
	if (MP_SUOL_hiddenForScene()) {
		MP_SUOL_getManager().hideAll();
	}
	return true;
}
