#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
	name = "Bounce Analyser",
	author = "ILDPRUT",
	description = "Shows possible bounce methods",
	version = "1.0.6",
}

#define NaN										view_as<float>(0x7FFFFFFF)								// NaN
static const float NaNVector[3] =				{NaN, NaN, NaN};
#define Inf										view_as<float>(0x7F800000)								// Inf
#define EPSILON									0.001

#define TIMER_INTERVAL							0.1														// Interval for live checking update

#define DIST_EPSILON							0.03125													// 1/(1 << 5) = 0.3125 // From coordsize.h
#define TICK_INTERVAL							0.015													// 1/0.015 = 66.6666...

#define JUMPVEL									289.0													// From CTFGameMovement::CheckJumpButton
#define MAXVEL									3500.0													// sv_maxvelocity
#define GRAVITY									(-800.0)												// -sv_gravity
#define ACCELERATION							10.0													// sv_accelerate
#define FRICTION								4.0														// sv_friction
#define STOP_SPEED								100.0													// sv_stopspeed

#define DUCK_SPEED_SCALE						0.33333333												// From CGameMovement::HandleDuckingSpeedCrop
#define BACK_SPEED_SCALE						0.9														// ConVar: tf_clamp_back_speed
#define BACK_SPEED_MIN							100.0													// ConVar: tf_clamp_back_speed_min
#define WALK_SPEED_AIMING						80.0													// TF_COND_AIMING // From CTFPlayer::TeamFortress_CalculateMaxSpeed
#define WALK_SPEED_SOLDIER						240.0

// From CTFGameMovement::CategorizePosition
#define GROUND_LAND_INTERVAL					2.0
#define GROUND_NORMAL_MIN						0.7
#define GROUND_LEAVE_SPEED						250.0

// From g_TFViewVectors when game is loaded
#define HULL_WIDTH								48.0
#define HULL_HEIGHT								82.0
#define HULL_HEIGHT_DUCK						62.0
#define HULL_HEIGHT_OLD							55.0
#define HULL_HEIGHT_DIFF						(HULL_HEIGHT-HULL_HEIGHT_DUCK)
#define VIEW_HEIGHT								68.0
#define VIEW_HEIGHT_DUCK						45.0

// From CTFWeaponBaseGun::FireRocket and CTFWeaponBaseGun::FireEnergyBall
#define AIM_DISTANCE							2000.0
#define MASK_SURFACE							(MASK_SOLID^CONTENTS_MONSTER)

// From wiki.alliedmods.net/Team_Fortress_2_Item_Definition_Indexes
#define INDEX_DIRECTHIT							127
#define INDEX_LIBERTY							414
#define INDEX_MANGLER							441
#define INDEX_ORIGINAL							513
#define INDEX_BEGGARS							730
#define INDEX_AIRSTRIKE							1104

// From CTFWeaponBaseGun::FireRocket and CTFWeaponBaseGun::FireEnergyBall
#define OFFSET_FORWARD							23.5
#define OFFSET_UP								(-3.0)
#define OFFSET_UP_DUCK							8.0
#define OFFSET_STOCK							12.0
#define OFFSET_ORIGINAL							0.0
#define OFFSET_MANGLER							8.0

#define ROCKET_DAMAGE							90.0													// Found using CTFWeaponBaseGun::GetProjectileDamage
#define ROCKET_RADIUS							121.0													// From CTFBaseRocket::Explode and CTFProjectile_EnergyBall::Explode
#define ROCKET_RADIUS_CHARGED					(1.33*ROCKET_RADIUS)									// More precisely (float)0x4320EE14 = 160.9299926757812 ~ 160.93 = 1.33*ROCKET_RADIUS // Cow Mangler Alt Fire // From CTFProjectile_EnergyBall::Explode
#define ROCKET_FALLOFF							0.5														// From CTFRadiusDamageInfo::CalculateFalloff
#define ROCKET_SPEED							1100.0													// From CTFBaseRocket::Create and CTFParticleCannon::GetProjectileSpeed
#define ROCKET_SPEED_LIBERTY					(1.4*ROCKET_SPEED)										// = mult_projectile_speed*ROCKET_SPEED // From CTFBaseRocket::Create
#define ROCKET_SPEED_DIRECTHIT					(1.8*ROCKET_SPEED)										// = mult_projectile_speed*ROCKET_SPEED // From CTFBaseRocket::Create
#define ROCKET_SURFACE_OFFSET					1.0														// From CTFBaseRocket::Explode and CTFProjectile_EnergyBall::Explode

#define BLAST_PUSH_OFFSET_Z						(-10.0)													// From CTFPlayer::OnTakeDamage_Alive

#define DAMAGE_FACTOR_SOLDIER_AIR				0.6														// When not on ground or in water (FL_ONGROUND | FL_INWATER) // From CTFPlayer::OnTakeDamage
#define DAMAGE_FACTOR_DEMOMAN_WEAPON			0.75													// Using Grenade Launcher (ID:23) or Sticky Bomb Launcher (ID:24) // From CTFRadiusDamageInfo::ApplyToEntity

// From CTFPlayer::ApplyPushFromDamage
// Knockback factor from ducking was originally calculated using STANDING_VOLUME / CURRENT_VOLUME = VEC_HULL_SIZE[2] / VEC_CURRENT_HULL_SIZE[2], but it seems they changed VEC_DUCK_HULL_SIZE[2] from 55 to 62, and to keep jumping consistent they hardcoded 55 into the factoring.
#define PUSH_SCALE_STAND						1.0
#define PUSH_SCALE_DUCK							(HULL_HEIGHT/HULL_HEIGHT_OLD)

#define PUSH_SCALE_DEFAULT						9.0														// From CTFPlayer::ApplyPushFromDamage
#define PUSH_SCALE_SOLDIER_GROUND				5.0														// If FL_ONGROUND // ConVar: tf_damageforcescale_self_soldier_badrj
#define PUSH_SCALE_SOLDIER						10.0													// ConVar: tf_damageforcescale_self_soldier_rj
#define PUSH_SCALE_PYRO							8.5														// ConVar: tf_damageforcescale_pyro_jump

enum
{
	UNCROUCHED,
	CROUCHED
}

enum
{
	LAUNCHER_STOCK,
	LAUNCHER_ORIGINAL,
	LAUNCHER_MANGLER,
	LAUNCHER_COUNT
}

enum
{
	BOUNCE_START_FALL,
	BOUNCE_START_WALK,
	BOUNCE_START_CROUCHWALK,
	BOUNCE_START_JUMP,
	BOUNCE_START_CROUCHJUMP,
	BOUNCE_START_CTAPJUMP,
	BOUNCE_START_CEILING,
	BOUNCE_START_ANGLE_STANDING,
	BOUNCE_START_ANGLE_DUCKING,
	BOUNCE_START_COUNT
}

enum
{
	BOUNCE_TYPE_UNCROUCHED,
	BOUNCE_TYPE_CROUCHED,
	BOUNCE_TYPE_JUMPBUG,
	BOUNCE_TYPE_COUNT
}

enum
{
	GROUND_NONE,
	GROUND_CHANGED,
	GROUND_UNCHANGED,
	GROUND_STEEP
}

enum
{
	SURFACE_NONE,
	SURFACE_FLOOR,
	SURFACE_CEILING,
	SURFACE_WALL
}

enum
{
	ENTITY_NONE = -1,
	ENTITY_INVALID = -2
}

enum struct Plane
{
	int edict;
	float dist;
	float normal[3];

	void InitVars(const int edict, float dist, const float[] normal)
	{
		this.edict = edict;
		this.dist = dist;
		CopyVector(normal, this.normal);
	}
}

enum struct Session
{
	Plane ground;
	Plane trigger;
	Plane floor;
	Plane ceiling;
	Plane wall;
	Plane wall_ground;
	ArrayList bounces;
	int indexer[BOUNCE_TYPE_COUNT*(BOUNCE_START_COUNT+1)]; // BOUNCE_START_ANGLE_STANDING is for the simplest launcher strat, BOUNCE_START_ANGLE_DUCKING is for the simplest strat for the player's launcher, and BOUNCE_START_COUNT is the angled start for the player's launcher
	int displayed;

	bool grounded;
	float landtick;
}

enum struct Launcher
{
	int launcher;
	bool charged;
}

enum struct Bounce
{
	int start;
	int type;
	Launcher launcher;
	float pitch;
	int input[2];
}

float LAUNCHER_RADIUS[2];
float LAUNCHER_OFFSET[LAUNCHER_COUNT][2][3];
float BOUNCE_START[BOUNCE_START_COUNT][2];

char TEXT_BOUNCE_START[BOUNCE_START_COUNT][50];
char TEXT_BOUNCE_TYPE[BOUNCE_TYPE_COUNT][50];
char TEXT_BOUNCE_INPUT[3][3][50];
char TEXT_LAUNCHER[LAUNCHER_COUNT+1][50];

bool g_paneldraw = false;
Session g_sessions[MAXPLAYERS+1];

ConVar g_convar_live;
Handle g_timer_live;

public void OnPluginStart()
{
	/* INITIALISE SESSIONS */
	for (int client = 0; client <= MaxClients; client++) {
		g_sessions[client].bounces = new ArrayList(sizeof(Bounce));
		ClearSession(client);
	}

	/* SET ARRAYS */
	BOUNCE_START[BOUNCE_START_FALL]          [0] =               0.0; BOUNCE_START[BOUNCE_START_FALL]          [1] =                                   NaN; // Fall
	BOUNCE_START[BOUNCE_START_WALK]          [0] =               0.0; BOUNCE_START[BOUNCE_START_WALK]          [1] = 0.5*(GRAVITY*TICK_INTERVAL)          ; // Walk
	BOUNCE_START[BOUNCE_START_CROUCHWALK]    [0] = -HULL_HEIGHT_DIFF; BOUNCE_START[BOUNCE_START_CROUCHWALK]    [1] = 0.5*(GRAVITY*TICK_INTERVAL)          ; // Crouchwalk
	BOUNCE_START[BOUNCE_START_JUMP]          [0] =               0.0; BOUNCE_START[BOUNCE_START_JUMP]          [1] = 0.5*(GRAVITY*TICK_INTERVAL) + JUMPVEL; // Jump
	BOUNCE_START[BOUNCE_START_CROUCHJUMP]    [0] =               0.0; BOUNCE_START[BOUNCE_START_CROUCHJUMP]    [1] =                               JUMPVEL; // Crouchjump
	BOUNCE_START[BOUNCE_START_CTAPJUMP]      [0] = -HULL_HEIGHT_DIFF; BOUNCE_START[BOUNCE_START_CTAPJUMP]      [1] =                               JUMPVEL; // C-tap jump
	BOUNCE_START[BOUNCE_START_CEILING]       [0] =      -HULL_HEIGHT; BOUNCE_START[BOUNCE_START_CEILING]       [1] = 0.5*(GRAVITY*TICK_INTERVAL)          ; // Ceiling
	BOUNCE_START[BOUNCE_START_ANGLE_STANDING][0] =               0.0; BOUNCE_START[BOUNCE_START_ANGLE_STANDING][1] =                                   NaN; // Standing using launcher
	BOUNCE_START[BOUNCE_START_ANGLE_DUCKING] [0] = -HULL_HEIGHT_DIFF; BOUNCE_START[BOUNCE_START_ANGLE_DUCKING] [1] =                                   NaN; // Ducking using launcher

	LAUNCHER_RADIUS[0] = ROCKET_RADIUS;			// Normal
	LAUNCHER_RADIUS[1] = ROCKET_RADIUS_CHARGED; // Charged

	float offsets[3] = {OFFSET_STOCK, OFFSET_ORIGINAL, OFFSET_MANGLER};
	float offset[3] = {OFFSET_FORWARD, NaN, NaN};
	for (int launcher = 0; launcher < LAUNCHER_COUNT; launcher++) {
		offset[1] = offsets[launcher];
		offset[2] = OFFSET_UP        ; CopyVector(offset, LAUNCHER_OFFSET[launcher][UNCROUCHED]); // Uncrouched
		offset[2] = OFFSET_UP_DUCK   ; CopyVector(offset, LAUNCHER_OFFSET[launcher][CROUCHED]  ); // Crouched
	}

	TEXT_BOUNCE_START[BOUNCE_START_FALL]           = "Fall";
	TEXT_BOUNCE_START[BOUNCE_START_WALK]           = "Walk off";
	TEXT_BOUNCE_START[BOUNCE_START_CROUCHWALK]     = "Crouchwalk off";
	TEXT_BOUNCE_START[BOUNCE_START_JUMP]           = "Jump off";
	TEXT_BOUNCE_START[BOUNCE_START_CROUCHJUMP]     = "Crouchjump off";
	TEXT_BOUNCE_START[BOUNCE_START_CTAPJUMP]       = "C-tap off";
	TEXT_BOUNCE_START[BOUNCE_START_CEILING]        = "Hit ceiling";
	TEXT_BOUNCE_START[BOUNCE_START_ANGLE_STANDING] = "Walk ";
	TEXT_BOUNCE_START[BOUNCE_START_ANGLE_DUCKING]  = "Crouch ";

	TEXT_BOUNCE_TYPE[BOUNCE_TYPE_UNCROUCHED] = "Uncrouched";
	TEXT_BOUNCE_TYPE[BOUNCE_TYPE_CROUCHED]   = "Crouched";
	TEXT_BOUNCE_TYPE[BOUNCE_TYPE_JUMPBUG]    = "Jumpbug";

	TEXT_BOUNCE_INPUT[0][0] = "Back+Left";
	TEXT_BOUNCE_INPUT[0][1] = "Back";
	TEXT_BOUNCE_INPUT[0][2] = "Back+Right";
	TEXT_BOUNCE_INPUT[1][0] = "Left";
	TEXT_BOUNCE_INPUT[1][1] = "Stand";
	TEXT_BOUNCE_INPUT[1][2] = "Right";
	TEXT_BOUNCE_INPUT[2][0] = "Forward+Left";
	TEXT_BOUNCE_INPUT[2][1] = "Forward";
	TEXT_BOUNCE_INPUT[2][2] = "Forward+Right";

	TEXT_LAUNCHER[LAUNCHER_STOCK]     = "Stock";
	TEXT_LAUNCHER[LAUNCHER_ORIGINAL]  = "Original";
	TEXT_LAUNCHER[LAUNCHER_MANGLER]   = "Mangler";
	TEXT_LAUNCHER[LAUNCHER_MANGLER+1] = "Mangler Alt.";

	RegConsoleCmd("sm_bounce", Command_Bounce);
	RegConsoleCmd("sm_bcheck", Command_Bounce);

	g_convar_live = CreateConVar("sm_abounce_live", "0", "Enables live checking");
	AutoExecConfig(true, "abounce");

	if (g_convar_live.BoolValue) {
		g_timer_live = CreateTimer(TIMER_INTERVAL, Timer_Live, _, TIMER_REPEAT);
	}

	g_convar_live.AddChangeHook(ConVarChanged_Live);
}

public void OnClientConnected(int client)
{
	ClearSession(client);
}

public void OnClientDisconnect_Post(int client)
{
	ClearSession(client);
}

public void ConVarChanged_Live(ConVar convar, const char[] old_value, const char[] new_value)
{
	if (strcmp(old_value, new_value) == 0)
		return;

	if (convar.BoolValue)
		g_timer_live = CreateTimer(TIMER_INTERVAL, Timer_Live, _, TIMER_REPEAT);
	else
		CloseHandle(g_timer_live);

}

public Action Timer_Live(Handle timer)
{
	for (int client = 1; client <= MaxClients; client++) {
		if (!IsClientInGame(client))
			continue;
		else if (!IsPlayerAlive(client))
			continue;

		if (g_sessions[client].ground.edict <= ENTITY_NONE)
			continue;

		float pos[3]; GetEntPropVector(client, Prop_Data, "m_vecOrigin", pos);
		float vel[3]; GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
		int ground = GetEntPropEnt(client, Prop_Data, "m_hGroundEntity");

		int ducked = (GetEntProp(client, Prop_Data, "m_fFlags") & FL_DUCKING) > 0;
		float landtick = GetLandTickFromStartZVel(TICK_INTERVAL, GRAVITY, MAXVEL, pos[2] - ducked*HULL_HEIGHT_DIFF + Pow(2.0,15.0), vel[2]); // Add max world length to avoid negative numbers

		float diff = landtick - g_sessions[client].landtick;
		bool changed = EPSILON <= FloatFraction(diff) < 1 - EPSILON;

		bool statechange = (g_sessions[client].grounded) ^ (ground >= 0);

		g_sessions[client].grounded = ground >= 0;
		g_sessions[client].landtick = landtick;

		if (statechange || changed&&ground==-1) {
			UpdateBounces(client);
			ShowMenu(client);
		}
	}

	return Plugin_Continue;
}

void ClearSession(int client)
{
	g_sessions[client].ground.InitVars(ENTITY_NONE, NaN, NaNVector);
	g_sessions[client].trigger.InitVars(ENTITY_NONE, NaN, NaNVector);
	g_sessions[client].floor.InitVars(ENTITY_NONE, NaN, NaNVector);
	g_sessions[client].ceiling.InitVars(ENTITY_NONE, NaN, NaNVector);
	g_sessions[client].wall.InitVars(ENTITY_NONE, NaN, NaNVector);
	g_sessions[client].bounces.Clear();
	for (int i = 0; i < BOUNCE_TYPE_COUNT*BOUNCE_START_COUNT; i++)
		g_sessions[client].indexer[i] = -1;
	g_sessions[client].displayed = BOUNCE_TYPE_COUNT;
}

int GetLauncher(int client)
{
	int launcheredict = GetPlayerWeaponSlot(client, 0);
	int launcherid = GetEntProp(launcheredict, Prop_Send, "m_iItemDefinitionIndex");

	int launcher;
	switch (launcherid) {
		case INDEX_ORIGINAL:
			launcher = LAUNCHER_ORIGINAL;
		case INDEX_MANGLER:
			launcher = LAUNCHER_MANGLER;
		case INDEX_DIRECTHIT, INDEX_LIBERTY, INDEX_BEGGARS, INDEX_AIRSTRIKE:
			launcher = -1;
		default:
			launcher = LAUNCHER_STOCK;
	}

	return launcher;
}

Action Command_Bounce(int client, int args)
{
	float ray_start[3];
	float ray_angle[3];
	GetClientEyePosition(client, ray_start);
	GetClientEyeAngles(client, ray_angle);

	UpdateGround(client, ray_start, ray_angle);

	UpdateBounces(client);

	ShowMenu(client);

	return Plugin_Handled;
}

/* SESSION */
void UpdateGround(int client, float start[3], float angle[3])
{
	int ground = FindGround(client, start, angle);

	if (ground == GROUND_CHANGED) {
		g_sessions[client].floor.InitVars(ENTITY_NONE, NaN, NaNVector);
		g_sessions[client].ceiling.InitVars(ENTITY_NONE, NaN, NaNVector);
		g_sessions[client].wall.InitVars(ENTITY_NONE, NaN, NaNVector);
	}

	if (ground != GROUND_NONE || g_sessions[client].floor.edict <= ENTITY_NONE) {
		bool newfloor = false;

		float pos[3];
		GetClientAbsOrigin(client, pos);

		Plane plane;
		FindPlane(ENTITY_NONE, pos, NaNVector, plane);
		if (plane.edict > ENTITY_NONE) {
			float dot = plane.dist - g_sessions[client].floor.dist;
			if (!CompareVectors(plane.normal, g_sessions[client].floor.normal) || FloatIsNaN(dot) || FloatAbs(dot) > EPSILON)
				newfloor = true;

			newfloor &= CompareVectors(plane.normal, {0.0, 0.0, 1.0});
		}

		if (newfloor)
			g_sessions[client].floor.InitVars(plane.edict, plane.dist, plane.normal);
	}

	if (ground == GROUND_CHANGED)
		g_sessions[client].displayed = BOUNCE_TYPE_COUNT;
}

int CompareBounces(int index1, int index2, Handle array, Handle datapack)
{
	Bounce bounce1; GetArrayArray(array, index1, bounce1);
	Bounce bounce2; GetArrayArray(array, index2, bounce2);

	int launcher = -1;
	if (datapack != INVALID_HANDLE) {
		ResetPack(datapack);
		launcher = ReadPackCell(datapack);
	}

	if (bounce1.type < bounce2.type)
		return -1;
	else if (bounce1.type > bounce2.type)
		return 1;

	if (bounce1.start == BOUNCE_START_FALL && bounce2.start != BOUNCE_START_FALL)
		return -1;
	else if (bounce1.start != BOUNCE_START_FALL && bounce2.start == BOUNCE_START_FALL)
		return 1;
	else if (bounce1.start < bounce2.start && bounce1.start <= BOUNCE_START_CEILING)
		return -1;
	else if (bounce1.start > bounce2.start && bounce2.start <= BOUNCE_START_CEILING)
		return 1;
	else if (bounce1.start <= BOUNCE_START_CEILING && bounce2.start <= BOUNCE_START_CEILING)
		return 0;

	int com1 = bounce1.input[0]*bounce1.input[0] + bounce1.input[1]*bounce1.input[1];
	int com2 = bounce2.input[0]*bounce2.input[0] + bounce2.input[1]*bounce2.input[1];

	if (com1 < com2)
		return -1;
	else if (com1 > com2)
		return 1;

	if (!FloatIsNaN(bounce1.pitch) && FloatIsNaN(bounce2.pitch))
		return -1;
	else if (FloatIsNaN(bounce1.pitch) && !FloatIsNaN(bounce2.pitch))
		return 1;

	if (bounce1.launcher.launcher == launcher || bounce2.launcher.launcher == launcher) {
		if (bounce2.launcher.launcher != launcher)
			return -1;
		if (bounce1.launcher.launcher != launcher)
			return 1;
	}
	else {
		if (bounce1.launcher.launcher < bounce2.launcher.launcher)
			return -1;
		else if (bounce1.launcher.launcher > bounce2.launcher.launcher)
			return 1;
	}

	if (com1 != 2 && com2 != 2) {
		if (bounce1.input[0] != 0 && bounce2.input[1] != 0)
			return -1;
		else if (bounce2.input[0] != 0 && bounce1.input[1] != 0)
			return 1;
	}

	if (bounce1.start < bounce2.start)
		return -1;
	else if (bounce1.start > bounce2.start)
		return 1;

	if (bounce1.launcher.charged < bounce2.launcher.charged)
		return -1;
	else if (bounce1.launcher.charged > bounce2.launcher.charged)
		return 1;

	return 0;
}

void UpdateBounces(int client)
{
	g_sessions[client].bounces.Clear();

	for (int type = 0; type < BOUNCE_TYPE_COUNT; type++) {
		Bounce bounce;
		bounce.type = type;

		for (int start = 0; start <= BOUNCE_START_CEILING; start++) {
			bounce.start = start;

			if (start == BOUNCE_START_FALL) {
				if (g_convar_live.BoolValue) {
					Plane floor; floor.InitVars(g_sessions[client].floor.edict, g_sessions[client].floor.dist, g_sessions[client].floor.normal);

					float pos[3]; GetEntPropVector(client, Prop_Data, "m_vecOrigin", pos);
					float vel[3]; GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
					if (GetEntProp(client, Prop_Data, "m_fFlags") & FL_DUCKING)
						pos[2] -= HULL_HEIGHT_DIFF;

					g_sessions[client].floor.InitVars(ENTITY_INVALID, pos[2] - DIST_EPSILON, {0.0, 0.0, 1.0});

					BOUNCE_START[BOUNCE_START_FALL][1] = vel[2];

					if (!g_sessions[client].grounded && CheckBounce(g_sessions[client], bounce))
						g_sessions[client].bounces.PushArray(bounce);

					g_sessions[client].floor.InitVars(floor.edict, floor.dist, floor.normal);
				}
            }
			else if (CheckBounce(g_sessions[client], bounce))
				g_sessions[client].bounces.PushArray(bounce);
		}

		for (int l = 0; l < LAUNCHER_COUNT; l++) {
			bounce.launcher.launcher = l;

			// Add angled bounce for launcher
			bounce.start = BOUNCE_START_ANGLE_STANDING;
			bounce.pitch = NaN;
			bounce.input[0] = 0;
			bounce.input[1] = 0;
			bounce.launcher.charged = false;

			float pitch[2];
			GetPitchInterval(g_sessions[client], bounce, pitch);
			if (!FloatIsNaN(pitch[0]) && !FloatIsNaN(pitch[1]))
				g_sessions[client].bounces.PushArray(bounce);

			bounce.pitch = DegToRad(89.0);
			int cm = view_as<int>(l == LAUNCHER_MANGLER);

			for (int c = 0; c <= cm; c++) {
				bounce.launcher.charged = !!c; // Convert c to bool

				for (int start = BOUNCE_START_ANGLE_STANDING; start < BOUNCE_START_COUNT; start++) {
					bounce.start = start;

					for (int f = -1; f <= 1; f++) {
						int side = l == LAUNCHER_ORIGINAL ? 0 : -1;

						for (int r = side; r <= 1; r++) {
							bounce.input[0] = f; bounce.input[1] = r;

							if (CheckBounce(g_sessions[client], bounce))
								g_sessions[client].bounces.PushArray(bounce);
						} // H
					} // e
				} // l
			} // l
		} // o
	} // !

	SortADTArrayCustom(g_sessions[client].bounces, CompareBounces, INVALID_HANDLE);

	for (int i = 0; i < BOUNCE_TYPE_COUNT*(BOUNCE_START_COUNT+1); i++)
		g_sessions[client].indexer[i] = -1;

	int launcher = GetLauncher(client);
	DataPack datapack = new DataPack();
	datapack.WriteCell(launcher);

	for (int i = 0; i < g_sessions[client].bounces.Length; i++) {
		Bounce bounce; g_sessions[client].bounces.GetArray(i, bounce);

		char bounces[50];
		BounceString(g_sessions[client], bounce, bounces, sizeof(bounces));

		if (bounce.start <= BOUNCE_START_CEILING) {
			g_sessions[client].indexer[bounce.type*(BOUNCE_START_COUNT+1) + bounce.start] = i;
		}
		else {
			int strats = bounce.type*(BOUNCE_START_COUNT+1) + BOUNCE_START_ANGLE_STANDING;
			int stratl = bounce.type*(BOUNCE_START_COUNT+1) + BOUNCE_START_ANGLE_DUCKING;
			int strata = bounce.type*(BOUNCE_START_COUNT+1) + BOUNCE_START_COUNT;

			if (FloatIsNaN(bounce.pitch)) {
				if (bounce.launcher.launcher == launcher)
					g_sessions[client].indexer[strata] = i;

				continue;
			}

			if (g_sessions[client].indexer[strats] == -1)
				g_sessions[client].indexer[strats] = i;
			else if (CompareBounces(i, g_sessions[client].indexer[strats], g_sessions[client].bounces, datapack) == -1)
				g_sessions[client].indexer[strats] = i;

			if (bounce.launcher.launcher == launcher) {
				if (g_sessions[client].indexer[stratl] == -1)
					g_sessions[client].indexer[stratl] = i;
				else if (CompareBounces(i, g_sessions[client].indexer[stratl], g_sessions[client].bounces, datapack) == -1)
					g_sessions[client].indexer[stratl] = i;
			}
		}
	}

	delete datapack;
}

void BounceString(Session session, Bounce bounce, char[] buffer, int size)
{
	if (bounce.start <= BOUNCE_START_CEILING) {
		strcopy(buffer, size, TEXT_BOUNCE_START[bounce.start]);
	}
	else {
		int li = bounce.launcher.charged ? bounce.launcher.launcher + 1 : bounce.launcher.launcher;
		int f = bounce.input[0]; int r = bounce.input[1];

		if (FloatIsNaN(bounce.pitch)) {
			// Best place to calculate angled bounces sadly
			float pitch[2];
			GetPitchInterval(session, bounce, pitch);
			FormatEx(buffer, size, "(%s) %.2f°-%.2f°", TEXT_LAUNCHER[bounce.launcher.launcher], float(RoundToCeil(RadToDeg(pitch[0])*100))/100 + 0.005, float(RoundToFloor(RadToDeg(pitch[1])*100))/100 + 0.005);
		}
		else if (f == 0 && r == 0) {
			if (bounce.start == BOUNCE_START_ANGLE_STANDING)
				FormatEx(buffer, size, "(%s) Stand", TEXT_LAUNCHER[li]);
			else if (bounce.start == BOUNCE_START_ANGLE_DUCKING)
				FormatEx(buffer, size, "(%s) Crouch", TEXT_LAUNCHER[li]);
		}
		else {
			if (bounce.launcher.launcher == LAUNCHER_ORIGINAL && bounce.input[1] != 0)
				FormatEx(buffer, size, "(%s) %s%s/%s", TEXT_LAUNCHER[li], TEXT_BOUNCE_START[bounce.start], TEXT_BOUNCE_INPUT[f+1][0], TEXT_BOUNCE_INPUT[1][2]);
			else
				FormatEx(buffer, size, "(%s) %s%s", TEXT_LAUNCHER[li], TEXT_BOUNCE_START[bounce.start], TEXT_BOUNCE_INPUT[f+1][r+1]);
		}
	}
}

void DrawBounceType(int client, Panel panel, int type)
{
	char line[50];

	bool empty = true;
	bool hassimple = false;
	for (int start = 0; start <= BOUNCE_START_COUNT; start++) {
		if (g_sessions[client].indexer[type*(BOUNCE_START_COUNT+1) + start] >= 0) {
			empty = false;

			if (start < BOUNCE_START_CEILING && start != BOUNCE_START_FALL)
				hassimple = true;
		}
	}

	panel.CurrentKey = 3 + type;

	strcopy(line, sizeof(line), TEXT_BOUNCE_TYPE[type]);
	if (empty || g_sessions[client].floor.edict <= ENTITY_NONE && g_sessions[client].ceiling.edict <= ENTITY_NONE) {
		panel.DrawItem(line, ITEMDRAW_DISABLED);

		if (empty)
			return;
	}
	else {
		panel.DrawItem(line);
	}

	bool drawall = g_sessions[client].displayed != BOUNCE_TYPE_COUNT;
	int size = drawall ? g_sessions[client].bounces.Length : BOUNCE_START_COUNT+1;

	for (int i = 0; i < size; i++) {
		int index = drawall ? i : g_sessions[client].indexer[type*(BOUNCE_START_COUNT+1) + i];

		if (index < 0)
			continue;

		Bounce bounce; g_sessions[client].bounces.GetArray(index, bounce);

		if (drawall && bounce.type != type)
			continue;

		if (!drawall) {
			if (i > BOUNCE_START_CEILING && hassimple)
				continue;

			int indexl = g_sessions[client].indexer[type*(BOUNCE_START_COUNT+1) + BOUNCE_START_ANGLE_DUCKING];

			if (i == BOUNCE_START_ANGLE_STANDING && index == indexl)
				continue;

			if (i == BOUNCE_START_COUNT && indexl >= 0) {
				Bounce bouncel; g_sessions[client].bounces.GetArray(indexl, bouncel);

				if (bouncel.input[0]*bouncel.input[0] + bouncel.input[1]*bouncel.input[1] == 0)
					continue;
			}
		}

		BounceString(g_sessions[client], bounce, line, sizeof(line));
		Format(line, sizeof(line), "    %s", line);

		// Need to add 10 for some reason
		if (strlen(line) + strlen("    and more...") + 10 <= panel.TextRemaining) {
			panel.DrawText(line);
		}
		else {
			panel.DrawText("    and more...");
			break;
		}
	}
}

void ShowMenu(int client)
{
	char line[50];
	char addl[20];
	char snum[10];

	Panel panel = new Panel();
	panel.SetTitle("Bounce analyser");

	float groundangle = RadToDeg(ArcCosine(g_sessions[client].ground.normal[2]));
	bool steep = g_sessions[client].ground.normal[2] < GROUND_NORMAL_MIN;
	if (g_sessions[client].ground.edict > ENTITY_NONE) {
		if (!steep)
			FormatEx(line, sizeof(line), "Ground slope: %d°", RoundToNearest(groundangle));
		else
			FormatEx(line, sizeof(line), "Ground slope: %d° (too steep)", RoundToNearest(groundangle));
	}
	else
		FormatEx(line, sizeof(line), "No ground selected");

	panel.DrawText(line);

	float triggerheight = GetTriggerHeight(g_sessions[client]);
	FloatString(triggerheight, snum, sizeof(snum));
	if (g_sessions[client].trigger.edict > ENTITY_NONE) {
		if (CompareVectors(g_sessions[client].ground.normal, g_sessions[client].trigger.normal))
			FormatEx(addl, sizeof(addl), "");
		else if (IsWallValid(g_sessions[client]))
			FormatEx(addl, sizeof(addl), " (wall)");
		else
			FormatEx(addl, sizeof(addl), " (point)");

		if (FloatIsNaN(triggerheight))
			FormatEx(line, sizeof(line), "Teleport height: Undefined");
		if (triggerheight <= GROUND_LAND_INTERVAL + EPSILON)
			FormatEx(line, sizeof(line), "Teleport height: %s%s", snum, addl);
		else if (triggerheight <= GROUND_LAND_INTERVAL + BOUNCE_START[BOUNCE_START_JUMP][1]*TICK_INTERVAL + EPSILON)
			FormatEx(line, sizeof(line), "Teleport height: %s%s (jumpbug only)", snum, addl);
		else
			FormatEx(line, sizeof(line), "Teleport height: %s%s (impossible)", snum, addl);
	}
	else if (g_sessions[client].trigger.edict == ENTITY_INVALID) {
		FormatEx(line, sizeof(line), "Bad teleport orientation");
	}
	else {
		FormatEx(line, sizeof(line), "No teleport found");
	}

	panel.DrawText(line);

	if (CompareVectors(g_sessions[client].ground.normal, {0.0, 0.0, 1.0}))
		FormatEx(addl, sizeof(addl), "");
	else if (IsWallValid(g_sessions[client]))
		FormatEx(addl, sizeof(addl), " (wall)");
	else
		FormatEx(addl, sizeof(addl), " (point)");

	float floorheight = g_sessions[client].floor.dist - GetGroundZ(g_sessions[client]);
	FloatString(floorheight, snum, sizeof(snum));
	if (g_sessions[client].floor.edict > ENTITY_NONE) {
		if (FloatIsNaN(floorheight))
			FormatEx(line, sizeof(line), "Floor height: Undefined");
		else
			FormatEx(line, sizeof(line), "Floor height: %s%s", snum, addl);
	}
	else {
		FormatEx(line, sizeof(line), "No floor selected");
	}

	panel.DrawText(line);

	float ceilingheight = -g_sessions[client].ceiling.dist - GetGroundZ(g_sessions[client]);
	FloatString(ceilingheight, snum, sizeof(snum));
	if (g_sessions[client].ceiling.edict > ENTITY_NONE)
		if (FloatIsNaN(ceilingheight))
			FormatEx(line, sizeof(line), "Ceiling height: Undefined");
		else
			FormatEx(line, sizeof(line), "Ceiling height: %s%s", snum, addl);
	else
		FormatEx(line, sizeof(line), "No ceiling selected");

	panel.DrawText(line);

	panel.CurrentKey = 1;
	panel.DrawItem("Select ground");
	panel.CurrentKey = 2;
	panel.DrawItem("Select surface");

	int typestart = 0;
	int typeend = BOUNCE_TYPE_COUNT;
	if (g_sessions[client].displayed != BOUNCE_TYPE_COUNT) {
		typestart = g_sessions[client].displayed;
		typeend = typestart + 1;
	}

	for (int type = typestart; type < typeend; type++)
		DrawBounceType(client, panel, type);

 	panel.CurrentKey = 10;
	panel.DrawItem("Exit");

	g_paneldraw = true;
	panel.Send(client, PanelHandler, 0);
	g_paneldraw = false;

	delete panel;
}

public int PanelHandler(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select) {
		if (choice == 10) {
			ClearSession(client);
			return;
		}

		if (choice <= 2) {
			float ray_start[3];
			float ray_angle[3];
			GetClientEyePosition(client, ray_start);
			GetClientEyeAngles(client, ray_angle);

			if (choice == 1)
				UpdateGround(client, ray_start, ray_angle);
			else if (choice == 2)
				FindSurface(client, ray_start, ray_angle);

			UpdateBounces(client);
		}

		if (3 <= choice <= 5) {
			if (g_sessions[client].displayed == BOUNCE_TYPE_COUNT) {
				switch (choice) {
					case 3:
						g_sessions[client].displayed = BOUNCE_TYPE_UNCROUCHED;
					case 4:
						g_sessions[client].displayed = BOUNCE_TYPE_CROUCHED;
					case 5:
						g_sessions[client].displayed = BOUNCE_TYPE_JUMPBUG;
				}
			}
			else {
				g_sessions[client].displayed = BOUNCE_TYPE_COUNT;
			}
		}

		ShowMenu(client);
	}
	else if (action == MenuAction_Cancel) {
		if (!g_paneldraw)
			ClearSession(client);
	}
}

/* PLUGIN */
bool TraceEntityFilterPlayer(int entity, int contentsMask) { return (entity == 0 || entity > MaxClients); }

void FindPlane(int edict, const float start[3], const float angle[3], Plane plane)
{
	plane.InitVars(ENTITY_NONE, NaN, NaNVector);

	bool do_hull = FloatIsNaN(angle[0]) || FloatIsNaN(angle[1]) || FloatIsNaN(angle[2]); // Being NaN means hull check down

	float mins[3];
	float maxs[3];
	if (do_hull) {
		mins[0] = -HULL_WIDTH/2.0; mins[1] = -HULL_WIDTH/2.0; mins[2] = 0.0;
		maxs[0] =  HULL_WIDTH/2.0; maxs[1] =  HULL_WIDTH/2.0; maxs[2] = HULL_HEIGHT_DUCK;
	}
	else {
		mins[0] = -DIST_EPSILON/2.0; mins[1] = -DIST_EPSILON/2.0; mins[2] = 0.0;
		maxs[0] =  DIST_EPSILON/2.0; maxs[1] =  DIST_EPSILON/2.0; maxs[2] = DIST_EPSILON;
	}

	Handle trace_rough;
	if (edict > ENTITY_NONE)
	{
		trace_rough = TR_ClipRayToEntityEx(start, angle, MASK_ALL, RayType_Infinite, edict);
	}
	else if (do_hull) {
		float end[3];
		end[0] = start[0]; end[1] = start[1]; end[2] = start[2] - GROUND_LAND_INTERVAL;
		trace_rough = TR_TraceHullFilterEx(start, end, mins, maxs, MASK_PLAYERSOLID, TraceEntityFilterPlayer);
	}
	else {
		trace_rough = TR_TraceRayFilterEx(start, angle, MASK_PLAYERSOLID, RayType_Infinite, TraceEntityFilterPlayer);
	}

	if (TR_DidHit(trace_rough)) {
		float point[3];
		float normal[3];
		TR_GetEndPosition(point, trace_rough);
		TR_GetPlaneNormal(trace_rough, normal);

		float startpoint[3];
		float endpoint[3];
		OffsetVector(point, normal, 1.0 - DIST_EPSILON, startpoint);
		OffsetVector(point, normal, -1.0 - DIST_EPSILON, endpoint);

		// Gets rid of some small errors and let's us be sure that the endpoint is DIST_EPSILON from surface.
		// Also have to use hull traces here because rays don't produce the 0.5 unit bug from VPhysics brushes.
		Handle trace_fine;
		if (edict > ENTITY_NONE)
			trace_fine = TR_ClipRayHullToEntityEx(startpoint, endpoint, mins, maxs, MASK_ALL, edict);
		else if (do_hull)
		{
			trace_fine = TR_TraceHullFilterEx(startpoint, endpoint, mins, maxs, MASK_PLAYERSOLID, TraceEntityFilterPlayer);
		}
		else
			trace_fine = TR_TraceHullFilterEx(startpoint, endpoint, mins, maxs, MASK_PLAYERSOLID, TraceEntityFilterPlayer);

		TR_GetEndPosition(point, trace_fine);
		float dist = DotVectors(point, normal) - DIST_EPSILON;

		plane.InitVars(TR_GetEntityIndex(trace_fine), dist, normal);

		CloseHandle(trace_fine);
	}

	CloseHandle(trace_rough);
}

int FindGround(int client, float start[3], float angle[3])
{
	int ground = GROUND_NONE;

	Plane plane;
	FindPlane(ENTITY_NONE, start, angle, plane);
	if (plane.edict > ENTITY_NONE) {
		if (plane.normal[2] > EPSILON) {
			ground = GROUND_UNCHANGED;

			float dist_diff = plane.dist - g_sessions[client].ground.dist;

			if (!CompareVectors(plane.normal, g_sessions[client].ground.normal) || FloatIsNaN(dist_diff) || FloatAbs(dist_diff) > EPSILON)
				ground = GROUND_CHANGED;

			g_sessions[client].ground.InitVars(plane.edict, plane.dist, plane.normal);
			g_sessions[client].trigger.InitVars(ENTITY_NONE, NaN, NaNVector);

			float dir[3];
			float end[3];
			GetAngleVectors(angle, dir, NULL_VECTOR, NULL_VECTOR);
			OffsetVector(start, dir, (plane.dist - DotVectors(start, plane.normal)) / DotVectors(dir, plane.normal), end);

			DataPack datapack = new DataPack();
			datapack.WriteCell(client);
			datapack.WriteFloat(start[0]); datapack.WriteFloat(start[1]); datapack.WriteFloat(start[2]);
			datapack.WriteFloat(end[0]);   datapack.WriteFloat(end[1]);   datapack.WriteFloat(end[2]);
			datapack.WriteFloat(angle[0]); datapack.WriteFloat(angle[1]); datapack.WriteFloat(angle[2]);
			TR_EnumerateEntities(start, end, PARTITION_TRIGGER_EDICTS, RayType_EndPoint, FindTrigger, datapack);

			// Construct artificial wall at ground point
			float normal[3]; NormVector(plane.normal, normal, 2);
			g_sessions[client].wall_ground.InitVars(ENTITY_NONE, DotVectors(end, normal, 2) - HULL_WIDTH/2.0, normal);
		}
	}

	return ground;
}

// Needs g_trace to be valid
bool FindTrigger(int edict, DataPack datapack) {
	char classname[50];
	GetEntityClassname(edict, classname, sizeof(classname));
	if (!StrEqual(classname, "trigger_teleport"))
		return true;

	datapack.Reset();
	int client = datapack.ReadCell();
	float start[3]; start[0] = datapack.ReadFloat(); start[1] = datapack.ReadFloat(); start[2] = datapack.ReadFloat();
	float end[3];   end[0] = datapack.ReadFloat();   end[1] = datapack.ReadFloat();   end[2] = datapack.ReadFloat();
	float angle[3]; angle[0] = datapack.ReadFloat(); angle[1] = datapack.ReadFloat(); angle[2] = datapack.ReadFloat();

	Handle trace_test = TR_ClipRayToEntityEx(start, end, MASK_ALL, RayType_EndPoint, edict);
	bool didhit = TR_DidHit(trace_test);

	CloseHandle(trace_test);

	if (!didhit)
		return true;

	Plane plane;
	FindPlane(edict, start, angle, plane);
	if (plane.edict > ENTITY_NONE) {
		bool replace = plane.normal[2] > EPSILON;

		float dist_diff_old = g_sessions[client].trigger.dist - g_sessions[client].ground.dist;
		float dist_diff_new = plane.dist - g_sessions[client].ground.dist;

		// Trigger should be above the ground and lower than a previous found trigger
		if (dist_diff_new < 0.0 || (!FloatIsNaN(dist_diff_old) && dist_diff_old <= dist_diff_new))
			replace = false;

		if (!AreParallel(plane.normal, g_sessions[client].ground.normal))
			replace = false;

		if (replace) {
			g_sessions[client].trigger.InitVars(plane.edict, plane.dist, plane.normal);
		}
		else if (g_sessions[client].trigger.edict <= ENTITY_NONE) {
			g_sessions[client].trigger.edict = ENTITY_INVALID; // Way to report that a trigger was found, but incorrect normal
		}
	}

	return true;
}

int FindSurface(int client, float start[3], float angle[3])
{
	int surface = SURFACE_NONE;

	Plane plane;
	FindPlane(ENTITY_NONE, start, angle, plane);
	if (plane.edict > ENTITY_NONE) {

		if (CompareVectors(plane.normal, {0.0, 0.0, 1.0})){
			surface = SURFACE_FLOOR;
			g_sessions[client].floor.InitVars(plane.edict, plane.dist, plane.normal);
		}
		else if (CompareVectors(plane.normal, {0.0, 0.0, -1.0})) {
			surface = SURFACE_CEILING;
			g_sessions[client].ceiling.InitVars(plane.edict, plane.dist, plane.normal);
		}
		else if (FloatAbs(plane.normal[2] - 0.0) < EPSILON && (FloatAbs(plane.normal[0] - 0.0) < EPSILON || FloatAbs(plane.normal[1] - 0.0) < EPSILON)) {
			// Unselect same wall
			if (CompareVectors(plane.normal, g_sessions[client].wall.normal) && FloatAbs(plane.dist - g_sessions[client].wall.dist) < EPSILON) {
				surface = SURFACE_NONE;
				g_sessions[client].wall.InitVars(ENTITY_NONE, NaN, NaNVector);
			}
			else {
				surface = SURFACE_WALL;
				g_sessions[client].wall.InitVars(plane.edict, plane.dist, plane.normal);
			}
		}
	}

	return surface;
}

float GetWallZ(const Plane surface, const Plane wall)
{
	if (CompareVectors(surface.normal, {0.0, 0.0, 1.0}))
		return surface.dist;

	float dot = DotUnitVectors(surface.normal, wall.normal, 2);

	// Planes are not compatible
	if (FloatAbs(FloatAbs(dot) - 1.0) >= EPSILON)
		return NaN;

	float surface_norm[2]; surface_norm[0] = DotVectors(surface.normal, wall.normal); surface_norm[1] = surface.normal[2];
	NormVector(surface_norm, surface_norm, 2);

	float surface_dist = surface.dist;
	float wall_dist = wall.dist;

	if (dot < 0.0)
		wall_dist += HULL_WIDTH;

	return surface_norm[0]/surface_norm[1] * (surface_dist/surface_norm[0] - wall_dist);
}

bool IsWallValid(const Session session)
{
	return session.wall.edict > ENTITY_NONE && AreParallel(session.ground.normal, session.wall.normal, 2);
}

float GetSurfaceZ(const Session session, const Plane plane)
{
	if (plane.edict <= ENTITY_NONE)
		return NaN;

	float z = CompareVectors(plane.normal, {0.0, 0.0, 1.0}) ? plane.dist : NaN;
	// Calculate height if ground is angled
	if (FloatIsNaN(z)) {
		Plane wall;
		if (IsWallValid(session))
			wall.InitVars(session.wall.edict, session.wall.dist + DIST_EPSILON, session.wall.normal);
		else
			wall.InitVars(session.wall_ground.edict, session.wall_ground.dist, session.wall_ground.normal); // Use artificial wall

		z = GetWallZ(plane, wall);
	}

	return z;
}

float GetTriggerHeight(const Session session)
{
	float triggerheight = NaN;

	if (session.trigger.edict == ENTITY_NONE) {
		triggerheight = 0.0;
	}
	else if (session.trigger.edict > ENTITY_NONE) {
		triggerheight = (session.trigger.dist - session.ground.dist) / session.ground.normal[2];

		if (triggerheight < 0.0)
			triggerheight = 0.0;
	}

	return triggerheight;
}

float GetGroundZ(const Session session)
{
	return GetSurfaceZ(session, session.ground);
}

void GetInterval(const Bounce bounce, float triggerheight, float interval[2])
{
	interval[0] = bounce.type == BOUNCE_TYPE_JUMPBUG ? FloatMax(0.0, triggerheight - BOUNCE_START[BOUNCE_START_JUMP][1]*TICK_INTERVAL) : triggerheight;
	interval[1] = GROUND_LAND_INTERVAL;
}

float GetStartZVel(const Bounce bounce)
{
	float startzvel = BOUNCE_START[bounce.start][1];
	// Calculate zvel if rocket strat
	if (bounce.start == BOUNCE_START_ANGLE_STANDING || bounce.start == BOUNCE_START_ANGLE_DUCKING) {
		bool standing = bounce.start == BOUNCE_START_ANGLE_STANDING;
		bool charged = bounce.launcher.charged;

		// Calculate velocity
		int input[2]; input[0] = bounce.input[0]; input[1] = bounce.input[1];
		float dummy[2];

		float maxspeed = charged ? WALK_SPEED_AIMING : WALK_SPEED_SOLDIER;
		float wishspeed = standing ? maxspeed : maxspeed*DUCK_SPEED_SCALE;
		float startspeed = GetVelFromInput(maxspeed, BACK_SPEED_SCALE, BACK_SPEED_MIN, wishspeed, input, dummy);

		maxspeed = WALK_SPEED_SOLDIER;
		wishspeed = standing ? maxspeed : maxspeed*DUCK_SPEED_SCALE;
		float endspeed = GetVelFromInput(maxspeed, BACK_SPEED_SCALE, BACK_SPEED_MIN, wishspeed, input, dummy);

		// Calculate rocket distance
		float moved[2];
		float viewheight = standing ? VIEW_HEIGHT : VIEW_HEIGHT_DUCK;
		int launcherindex = standing ? UNCROUCHED : CROUCHED;
		if (endspeed != 0.0) {
			int ticks = GetRocketTicksFromPitch(viewheight, AIM_DISTANCE, LAUNCHER_OFFSET[bounce.launcher.launcher][launcherindex], TICK_INTERVAL, ROCKET_SPEED, bounce.pitch);
			GetMovedFromInput(TICK_INTERVAL, ACCELERATION, FRICTION, STOP_SPEED, wishspeed, startspeed, endspeed, ticks, input, moved);
		}
		float distance = GetDistanceFromPitch(viewheight, AIM_DISTANCE, LAUNCHER_OFFSET[bounce.launcher.launcher][launcherindex], moved, bounce.pitch);

		// Calculate startzvel
		float scale = standing ? PUSH_SCALE_STAND : PUSH_SCALE_DUCK;
		float radius = charged ? ROCKET_RADIUS_CHARGED : ROCKET_RADIUS;
		float hullheight = standing ? HULL_HEIGHT : HULL_HEIGHT_DUCK;
		startzvel = GetZVelFromDistance(scale*PUSH_SCALE_SOLDIER_GROUND, ROCKET_DAMAGE, radius, ROCKET_FALLOFF, hullheight, ROCKET_SURFACE_OFFSET, BLAST_PUSH_OFFSET_Z, distance);
	}

	return startzvel;
}

bool IsBounceValid(const Session session, const Bounce bounce)
{
	if (bounce.start >= BOUNCE_START_COUNT || bounce.type >= BOUNCE_TYPE_COUNT || bounce.launcher.launcher < 0 || bounce.launcher.launcher >= LAUNCHER_COUNT)
		return false;

	// No ground
	if (session.ground.edict <= ENTITY_NONE)
		return false;

	// Player needs to be able to stand on the ground
	if (session.ground.normal[2] < GROUND_NORMAL_MIN)
		return false;

	// Trigger should be valid
	if (session.trigger.edict == ENTITY_INVALID)
		return false;

	// Start surface needs to be known
	if (bounce.start != BOUNCE_START_CEILING && session.floor.edict == ENTITY_NONE || bounce.start == BOUNCE_START_CEILING && session.ceiling.edict <= ENTITY_NONE)
		return false;

	return true;
}

bool CheckBounce(const Session session, const Bounce bounce)
{
	if (!IsBounceValid(session, bounce))
		return false;

	Plane plane;
	if (bounce.start == BOUNCE_START_CEILING)
		plane.InitVars(session.ceiling.edict, session.ceiling.dist, session.ceiling.normal);
	else
		plane.InitVars(session.floor.edict, session.floor.dist, session.floor.normal);

	float triggerheight = GetTriggerHeight(session);

	float groundz = GetGroundZ(session);
	if (FloatIsNaN(groundz))
		return false;

	float height = plane.normal[2]*(plane.dist + DIST_EPSILON) - groundz + BOUNCE_START[bounce.start][0];
	if (bounce.type == BOUNCE_TYPE_CROUCHED)
		height += HULL_HEIGHT_DIFF;

	float startzvel = GetStartZVel(bounce);

	float interval[2];
	GetInterval(bounce, triggerheight, interval);

	return CanBounce(TICK_INTERVAL, GRAVITY, MAXVEL, height, startzvel, interval);
}

void GetPitchInterval(const Session session, Bounce bounce, float pitch[2])
{
	pitch[0] = NaN; pitch[1] = NaN;

	if (!IsBounceValid(session, bounce) || bounce.start < BOUNCE_START_ANGLE_STANDING)
		return;

	float triggerheight = GetTriggerHeight(session);

	float groundz = GetGroundZ(session);
	if (FloatIsNaN(groundz))
		return;

	float height = (session.floor.dist + DIST_EPSILON) - groundz + BOUNCE_START[bounce.start][0];
	if (bounce.type == BOUNCE_TYPE_CROUCHED)
		height += HULL_HEIGHT_DIFF;

	if (height < GetValidHeight(TICK_INTERVAL, GRAVITY, MAXVEL, GROUND_LEAVE_SPEED, height))
		return;

	float interval[2];
	GetInterval(bounce, triggerheight, interval);

	if (interval[0] >= interval[1] - EPSILON)
		return;

	bool standing = bounce.start == BOUNCE_START_ANGLE_STANDING;
	bool charged = bounce.launcher.charged;

	float viewheight = standing ? VIEW_HEIGHT : VIEW_HEIGHT_DUCK;
	int launcherindex = standing ? UNCROUCHED : CROUCHED;
	float scale = standing ? PUSH_SCALE_STAND : PUSH_SCALE_DUCK;
	float radius = charged ? ROCKET_RADIUS_CHARGED : ROCKET_RADIUS;
	float hullheight = standing ? HULL_HEIGHT : HULL_HEIGHT_DUCK;

	int mintick = RoundToCeil( GetLandTickFromStartZVel(TICK_INTERVAL, GRAVITY, MAXVEL, height, GROUND_LEAVE_SPEED) );

	float moved[2];
	float mindistance = GetMinimumDistance(viewheight, AIM_DISTANCE, LAUNCHER_OFFSET[bounce.launcher.launcher][launcherindex], moved);
	float zvel = GetZVelFromDistance(scale*PUSH_SCALE_SOLDIER_GROUND, ROCKET_DAMAGE, radius, ROCKET_FALLOFF, hullheight, ROCKET_SURFACE_OFFSET, BLAST_PUSH_OFFSET_Z, mindistance);
	int maxtick = RoundToFloor( GetLandTickFromStartZVel(TICK_INTERVAL, GRAVITY, MAXVEL, height, zvel) );

	for (int landtick = mintick; landtick <= maxtick; landtick++) {
		float startzvels[2];
		GetBounceStartZVelsFromLandTick(TICK_INTERVAL, GRAVITY, MAXVEL, height, interval, landtick, startzvels);

		if (startzvels[0] > zvel || startzvels[1] > zvel)
			continue;

		float temp[2];
		for (int i = 0; i < 2; i++) {
			float distance = GetDistanceFromZVel(scale*PUSH_SCALE_SOLDIER_GROUND, ROCKET_DAMAGE, radius, ROCKET_FALLOFF, hullheight, ROCKET_SURFACE_OFFSET, BLAST_PUSH_OFFSET_Z, startzvels[i]);
			temp[i] = GetPitchFromDistance(viewheight, AIM_DISTANCE, LAUNCHER_OFFSET[bounce.launcher.launcher][launcherindex], moved, distance);
		}

		if (FloatIsNaN(pitch[0]) || FloatIsNaN(pitch[1]) || temp[1] - temp[0] > pitch[1] - pitch[0]) {
			pitch[0] = temp[0];
			pitch[1] = temp[1];
		}
	}
}

/* BOUNCE */
float GetValidHeight(float ti, float gravity, float maxvel, float startzvel, float height)
{
	int ticktop = RoundToCeil(-startzvel/(gravity*ti));
	float maxzrel = ticktop >= 0 ? GetZFromTick(ti, gravity, maxvel, 0.0, startzvel, ticktop) : 0.0;

	return FloatMax(height, -maxzrel);
}

bool CanBounce(float ti, float gravity, float maxvel, float height, float startzvel, const float interval[2])
{
	float heightmax = GetValidHeight(ti, gravity, maxvel, startzvel, height - interval[0]);
	float heightmin = GetValidHeight(ti, gravity, maxvel, startzvel, height - interval[1]);

	float tickmax = GetLandTickFromStartZVel(ti, gravity, maxvel, heightmax, startzvel);
	float tickmin = GetLandTickFromStartZVel(ti, gravity, maxvel, heightmin, startzvel);

	return (height - interval[0] >= heightmax || height - interval[1] >= heightmin) && (RoundToFloor(tickmax) - RoundToCeil(tickmin)) >= 0.0;
}

void GetBounceStartZVelsFromLandTick(float ti, float gravity, float maxvel, float height, const float interval[2], int landtick, float startzvels[2])
{
	startzvels[0] = GetStartZVelFromLandTick(ti, gravity, maxvel, height - interval[0], landtick);
	startzvels[1] = GetStartZVelFromLandTick(ti, gravity, maxvel, height - interval[1], landtick);
}

/* MOVE */
/*
        [1,0]
 [1,-1]   ↑   [1,1]
       ↖     ↗
[0,-1]← [0,0] →[0,1]
       ↙     ↘
[-1,-1]   ↓   [-1,1]
       [-1,0]
*/
float GetVelFromInput(float maxspeed, float backscale, float backspeedmin, float wishspeed, const int input[2], float vel[2])
{
	float temp[3];
	temp[0] = float(input[0]); temp[1] = float(input[1]);

	if (temp[0] != 0.0 || temp[1] != 0.0)
		NormalizeVector(temp, temp);

	float speed = FloatMin(wishspeed, maxspeed);
	ScaleVector(temp, speed);

	if (speed > backspeedmin)
		temp[0] = FloatMax(temp[0], -speed*backscale);

	vel[0] = temp[0]; vel[1] = temp[1];
	return SquareRoot(vel[0]*vel[0] + vel[1]*vel[1]);
}

void GetMovedFromInput(float ti, float acceleration, float friction, float stopspeed, float accspeed, float startspeed, float endspeed, int ticks, const int input[2], float moved[2])
{
	if (ticks <= 0) {
		moved[0] = 0.0; moved[1] = 0.0;
		return;
	}

	float distance = 0.0;
	if (startspeed < friction*ti*stopspeed && ticks > 0) {
		startspeed = acceleration*ti*accspeed;
		distance += startspeed*ti;
		ticks--;
	}

	if (startspeed < stopspeed && startspeed < endspeed) {
		float addspeed = acceleration*ti*accspeed - friction*ti*stopspeed;
		float topspeed = FloatMin(stopspeed, endspeed);
		int ticksc = RoundToFloor((topspeed - startspeed)/addspeed);
		if (ticks < ticksc)
			ticksc = ticks;

		distance += startspeed*ti * ticksc + addspeed*ti * ticksc*(ticksc+1)/2.0;
		startspeed += addspeed * ticksc;
		ticks -= ticksc;

		if (ticks > 0) {
			addspeed = FloatMin(addspeed, endspeed - startspeed);
			distance += (startspeed + addspeed)*ti;
			startspeed += addspeed;
			ticks--;
		}
	}

	float a = 1 - friction*ti;
	float b = acceleration*ti*accspeed/(a-1);

	int endspeedticks = RoundToCeil( Logarithm( (endspeed + b)/(startspeed + b), a) );
	int ticks0 = ticks < endspeedticks ? ticks : (endspeedticks - 1);

	distance += a*ti*(startspeed + b)*(Pow(a, float(ticks0)) - 1)/(a - 1) - b*ti*ticks0;
	if (ticks >= endspeedticks)
		distance += endspeed*ti * (ticks - ticks0);

	float magnitude = SquareRoot(float(input[0]*input[0] + input[1]*input[1]));
	moved[0] = input[0]*distance/magnitude; moved[1] = input[1]*distance/magnitude;
}

/* FALL */
int GetMaxVelTickFromStartZVel(float ti, float gravity, float maxvel, float startzvel)
{
	return RoundToCeil( -(startzvel + maxvel)/(gravity*ti) );
}

float GetZFromTick(float ti, float gravity, float maxvel, float height, float startzvel, int tick)
{
	int maxveltick = GetMaxVelTickFromStartZVel(ti, gravity, maxvel, startzvel);
	int tick0 = tick < maxveltick ? tick : (maxveltick - 1);

	float z = height + (startzvel - 0.5*gravity*ti)*ti * tick0 + (tick0)*(tick0 + 1)*0.5*gravity*ti*ti; // Last part is written in a weird order to (try) avoid precision errors

	if (tick >= maxveltick)
		z -= maxvel*ti * (tick - tick0);

	return z;
}

//float GetZVelFromTick(float ti, float gravity, float maxvel, float startzvel, int tick)
//{
//	return FloatMax(startzvel + gravity*ti*tick, -maxvel);
//}

//float GetTickFromZVel(float ti, float gravity, float maxvel, float startzvel, int zvel)
//{
//	return zvel <= -maxvel ? (zvel - startzvel)/(gravity*ti) : NaN;
//}

float GetLandTickFromStartZVel(float ti, float gravity, float maxvel, float height, float startzvel)
{
	int tick0 = GetMaxVelTickFromStartZVel(ti, gravity, maxvel, startzvel) - 1;
	float z0 = GetZFromTick(ti, gravity, maxvel, height, startzvel, tick0);

	if (z0 <= 0.0)
		return -(startzvel + SquareRoot(startzvel*startzvel - 2.0*gravity*height)) / (gravity*ti);
	else
		return height/(maxvel*ti) + (1 + startzvel/maxvel)*tick0 + 0.5*gravity*ti/maxvel * tick0*tick0;
}

int GetMaxVelTickFromLandTick(float ti, float gravity, float maxvel, float height, int landtick)
{
	return RoundToCeil( 0.5 * (1.0 + SquareRoot( 1.0 + 8.0*(height - maxvel*ti*landtick) / (gravity*ti*ti) )) ) - 1; // Returns a higher incorrect value for falls that cannot reach maxvel
}

float GetStartZVelFromLandTick(float ti, float gravity, float maxvel, float height, int landtick)
{
	int tick0 = GetMaxVelTickFromLandTick(ti, gravity, maxvel, height, landtick) - 1;

	if (landtick <= tick0)
		return -0.5*gravity*ti*landtick - height/(landtick*ti);
	else
		return -0.5*gravity*ti*tick0 + ( maxvel*(landtick - tick0) - height/ti )/tick0;
}

/* DAMAGE */
float GetZVelFromDistance(float scale, float damage, float radius, float falloff, float height, float surface_offset, float push_offset, float L)
{
	// ZVEL = A * (1 + sqrt(L^2 + C^2)) * D/sqrt(L^2 + D^2)
	float A = scale * damage;
	float B = (falloff - 1.0) / radius;
	float C = surface_offset;
	float D = height/2.0 - (surface_offset + push_offset);

	return A * (1.0 + B*SquareRoot(P2(L) + P2(C))) * D/SquareRoot(P2(L) + P2(D));
}

float GetDistanceFromZVel(float scale, float damage, float radius, float falloff, float height, float surface_offset, float push_offset, float zvel)
{
	// ZVEL = A * (1 + sqrt(L^2 + C^2)) * D/sqrt(L^2 + D^2)
	float A = scale * damage;
	float B = (falloff - 1.0) / radius;
	float C = surface_offset;
	float D = height/2.0 - (surface_offset + push_offset);

	float E = zvel/A;

	// a*(L^2)^2 + b*(L^2) + c = 0
	float a = P2(P2(B) - P2(E/D));
	float b = 2.0 / P2(D) * ( P2(B*D) * (P2(B*C) - 1.0) - ( 1.0 + (P2(C) + P2(D))*P2(B) ) * P2(E) + P4(E) ); // Can't find a way to make this nice :(
	float c = (1.0 - P2(B*C + E))*(1.0 - P2(B*C - E));

	return SquareRoot( (-b - SquareRoot(P2(b) - 4.0*a*c)) / (2.0*a) ); // Lowest solution
}

/* ROCKET */
int GetRocketTicksFromPitch(float view, float extent, const float offset[3], float ti, float speed, float pitch)
{
	float moved[2];
	float distance = GetHitVectorFromPitch(view, extent, offset, moved, pitch, NULL_VECTOR);

	// distance = speed*ti*ticks
	return RoundToCeil( distance / (speed*ti) ); // plus -1 to 2 if unlucky
}

float GetDistanceFromPitch(float view, float extent, const float offset[3], const float moved[2], float pitch)
{
	float hit[3];
	GetHitVectorFromPitch(view, extent, offset, moved, pitch, hit);
	return SquareRoot(hit[0]*hit[0] + hit[1]*hit[1]);
}

void TransformFromPitch(float pitch, const float original[3], float transform[3])
{
	float dir[3][3];
	dir[0][0] = Cosine(pitch); dir[0][1] = 0.0; dir[0][2] =  -Sine(pitch);
	dir[1][0] =           0.0; dir[1][1] = 1.0; dir[1][2] =           0.0;
	dir[2][0] =   Sine(pitch); dir[2][1] = 0.0; dir[2][2] = Cosine(pitch);

	float copy[3]; CopyVector(original, copy);
	for (int i = 0; i < 3; i++) transform[i] = DotVectors(copy, dir[i]);
}

float GetHitVectorFromPitch(float view, float extent, const float offset[3], const float moved[2], float pitch, float hit[3])
{
	float tempf;
	float tempv[3];

	                  hit    [0] =      extent; hit    [1] =         0.0; hit    [2] =            0.0;
	float offsetl[3]; offsetl[0] =   offset[0]; offsetl[1] =  -offset[1]; offsetl[2] =      offset[2];
	float normal [3]; normal [0] = Sine(pitch); normal [1] =         0.0; normal [2] = -Cosine(pitch);
	SubtractVectors(hit, offsetl, hit);

	CopyVector(hit, tempv);
	tempf = DotVectors(tempv, normal);

	CopyVector(normal, tempv);
	ScaleVector(tempv, view);
	SubtractVectors(tempv, offsetl, tempv);

	tempf = DotVectors(tempv, normal) / tempf;
	ScaleVector(hit, tempf);

	// Return rocket travel distance
	tempf = GetVectorLength(hit);
	
	AddVectors(offsetl, hit, hit);

	TransformFromPitch(-pitch, hit, hit);

	hit[0] -= moved[0];
	hit[1] -= -moved[1];

	return tempf;
}

float GetPitchFromDistance(float view, float extent, const float offset[3], const float moved[2], float LF)
{
	float L = SquareRoot(P2(LF) + P2(view));

	// A*cos^2 + B*cos + (C*cos + D)*sin + E = 0
	float coeff[5];
	coeff[0] = P2(L)*(offset[0] + offset[2] - extent)*(offset[0] - offset[2] - extent) - P2(offset[1])*P2(extent);																							// A
	coeff[1] = -2*offset[2]*view*extent*(offset[0] - extent);																																				// B
	coeff[2] = 2*offset[2]*P2(L)*(offset[0] - extent);																																						// C
	coeff[3] = -2*view*extent*(P2(offset[1]) + P2(offset[2]));																																				// D
	coeff[4] = P2(extent)*( - P2(L) + P2(offset[1]) + P2(offset[2]) + P2(view)) + 2*offset[0]*extent*(P2(L) - P2(view)) + P2(view)*(P2(offset[0]) + P2(offset[1]) + P2(offset[2])) - P2(offset[0])*P2(L);	// E

	float angs[4];
	SolveTrigonometric(coeff, angs);

	float comp[4];
	for (int i = 0; i < 4; i++) { comp[i] = FloatIsNaN(angs[i]) ? Inf : FloatAbs(GetDistanceFromPitch(view, extent, offset, moved, angs[i]) - LF); }

	return angs[ FilterAngles(angs, comp) ];
}

float GetMinimumDistance(float view, float extent, const float offset[3], const float moved[2])
{
	// A*cos^2 + B*cos + (C*cos + D)*sin + E = 0
	float coeff[5];
	coeff[0] = 2*extent*view*offset[2] * ( P2(extent) - 2*extent*offset[0] + P2(offset[0]) - P2(offset[1]) - P2(offset[2]) );												// A
	coeff[1] = (2*(extent-offset[0])) * ( (P2(extent) - 2*extent*offset[0] + P2(offset[0]) + P2(offset[1]) + P2(offset[2]))*P2(view) + P2(extent)*P2(offset[2]) );			// B
	coeff[2] = -2*( P2(offset[1]) + 2*P2(offset[2]) ) * extent*view*(extent-offset[0]);																						// C
	coeff[3] = -2*offset[2]*( (P2(extent) - 2*extent*offset[0] + P2(offset[0]) + P2(offset[1]) + P2(offset[2]))*P2(view) + P2(extent)*(P2(offset[1]) + P2(offset[2])) );	// D
	coeff[4] = 2*offset[2]*extent*view*(P2(extent) - 2*extent*offset[0] + P2(offset[0]) + 2*P2(offset[1]) + 2*P2(offset[2]));												// E

	float angs[4];
	SolveTrigonometric(coeff, angs);

	float dists[4];
	for (int i = 0; i < 4; i++) { dists[i] = FloatIsNaN(angs[i]) ? Inf : GetDistanceFromPitch(view, extent, offset, moved, angs[i]); }

	return dists[ FilterAngles(angs, dists) ];
}

/* Supports movement
float GetPitchFromDistance(float view, float extent, const float offset[3], const float moved[2], float LF)
{
	float L = SquareRoot(P2(LF) + P2(view));

	// A*cos^2 + B*cos + (C*cos + D)*sin + E = 0
	float coeff[5];
	coeff[0] = P2(offset[1]*extent) + (P2(moved[0]) + P2(moved[1]) - P2(L))*(P2(offset[0] - extent) - P2(offset[2])) + 2.0*(moved[1]*offset[1]*extent - 2*moved[0]*offset[2]*view)*(offset[0] - extent); // A
	coeff[1] = -2.0*offset[2]*( view*P2(extent) - extent*(moved[0]*offset[2] + offset[0]*view) + moved[1]*offset[1]*view ); // B
	coeff[2] = 2.0*( offset[2]*(P2(moved[0]) + P2(moved[1]) - P2(L))*(offset[0] - extent) + moved[0]*h*(P2(offset[0]) + P2(extent) - P2(offset[2]) - 2*offset[0]*extent) + moved[1]*offset[1]*offset[2]*extent ); // C
	coeff[3] = 2.0*( (moved[1]*offset[1]*view - moved[0]*offset[2]*extent)*(offset[0] - extent) + view*extent*(P2(offset[1]) + P2(offset[2])) ); // D
	coeff[4] = 2.0*extent*( offset[0]*(P2(moved[0]) + P2(moved[1]) + P2(view) - P2(L) - moved[1]*offset[1]) - view*moved[0]*offset[2] ) - P2(offset[0])*(offset[0]*(P2(moved[0]) + P2(moved[1]) + P2(view) - P2(L)) + 2.0*moved[0]*offset[0]*offset[2]*view - P2(view)*(P2(offset[0]) + P2(offset[2])) - P2(extent)*( P2(moved[0]) + P2(offset[2]) + P2(view) + P2(offset[0] - moved[1]) - P2(L) ); // E

	float angs[4];
	SolveTrigonometric(coeff, angs);

	float comp[4];
	for (int i = 0; i < 4; i++) { comp[i] = FloatAbs(GetDistanceFromPitch(view, extent, offset, angs[i]) - LF); }

	return angs[ FilterAngles(angs, comp) ];
}

float GetMinimumDistance(float view, float extent, const float offset[3] const float moved[2])
{
	// A*cos^2 + B*cos + (C*cos + D)*sin + E = 0
	float coeff[5];
	coeff[0] = 2.0 * offset[2] * (P3(extent) * view + (-2.0 * view * offset[0] - 2.0 * moved[0] * offset[2]) * extent * extent + ((2.0 * moved[1] * offset[1] + offset[0] * offset[0] - offset[1] * offset[1] - offset[2] * offset[2]) * view + 2.0 * moved[0] * offset[0] * offset[2]) * extent - 2.0 * view * moved[1] * offset[0] * offset[1]); // A
	coeff[1] = 2.0 * (extent - offset[0]) * (extent * extent - 2.0 * extent * offset[0] + offset[0] * offset[0] + offset[1] * offset[1] + offset[2] * offset[2]) * view * view - 2.0 * moved[0] * offset[2] * (extent * extent - 2.0 * extent * offset[0] + offset[0] * offset[0] + offset[2] * offset[2]) * view + 2.0 * extent * offset[2] * offset[2] * (extent * extent - extent * offset[0] + moved[1] * offset[1]); // B
	coeff[2] = -2.0 * P3(extent) * moved[0] * offset[2] + ((-4.0 * offset[2] * offset[2] + 2.0 * offset[1] * (moved[1] - offset[1])) * view + 4.0 * moved[0] * offset[0] * offset[2]) * extent * extent + (-4.0 * offset[0] * (-offset[2] * offset[2] + offset[1] * (moved[1] - offset[1] / 2.0)) * view - 2.0 * moved[0] * offset[0] * offset[0] * offset[2] + 2.0 * moved[0] * P3(offset[2])) * extent + 2.0 * view * moved[1] * offset[1] * (offset[0] - offset[2]) * (offset[0] + offset[2]); // C
	coeff[3] = (-2 * extent * extent - 2 * view * view) * P3(offset[2]) - 2.0 * view * moved[0] * (extent - offset[0]) * offset[2] * offset[2] + ((-(2 * extent * extent) + 4.0 * extent * offset[0] - 2.0 * offset[0] * offset[0] - 2.0 * offset[1] * offset[1]) * (view * view) + 2.0 * (-moved[1] * offset[0] + extent * (moved[1] - offset[1])) * extent * offset[1]) * offset[2] - 2.0 * view * moved[0] * P3(extent - offset[0]); // D
	coeff[4] = 2.0 * (P3(extent) * view + (-2.0 * view * offset[0] + moved[0] * offset[2]) * extent * extent + ((2.0 * offset[2] * offset[2] + offset[0] * offset[0] - offset[1] * (moved[1] - 2.0 * offset[1])) * view - moved[0] * offset[0] * offset[2]) * extent + view * moved[1] * offset[0] * offset[1]) * offset[2]; // E

	float angs[4];
	SolveTrigonometric(coeff, angs);

	float dists[4];
	for (int i = 0; i < 4; i++) { dists[i] = GetDistanceFromPitch(view, extent, offset, angs[i]); }

	return dists[ FilterAngles(angs, dists) ];
}
*/

// Find lowest pair in comp and choose the index of the lowest angle
int FilterAngles(const float angs[4], const float comp[4])
{
	int min1 = (comp[0] < comp[1]) ? 0 : 1;
	int min2 = (comp[0] < comp[1]) ? 1 : 0;
	int min3 = (comp[2] < comp[3]) ? 2 : 3;
	int min4 = (comp[2] < comp[3]) ? 3 : 2;

	if (comp[min1] < comp[min4] && comp[min3] < comp[min2])
		min2 = min3;
	else if (comp[min3] < comp[min1]) {
		min1 = min3;
		min2 = min4;
	}

	return (angs[min1] < angs[min2]) ? min1 : min2;
}

/* Solutions */
// Solve A*cos^2 + B*cos + (C*cos + D)*sin + E = 0 for angles between 0 and pi
void SolveTrigonometric(const float coeff[5], float angs[4])
{
	// (A^2 + C^2)*x^4 + 2*(A*B + C*D)*x^3 + (2*A*E + B^2 - C^2 + D^2)*x^2 + 2*(B*E - C*D)*x + (E^2 - D^2) = 0
	//           a*x^4       +       b*x^3             +             c*x^2       +       d*x      +      e = 0
	float coeff_quad[5];
	coeff_quad[0] = P2(coeff[4]) - P2(coeff[3]);                                      // e
	coeff_quad[1] = 2*(coeff[1]*coeff[4] - coeff[2]*coeff[3]);                        // d
	coeff_quad[2] = 2*coeff[0]*coeff[4] + P2(coeff[1]) - P2(coeff[2]) + P2(coeff[3]); // c
	coeff_quad[3] = 2*(coeff[0]*coeff[1] + coeff[2]*coeff[3]);                        // b
	coeff_quad[4] = P2(coeff[0]) + P2(coeff[2]);                                      // a

	float zeros[4];
	SolveQuadric(coeff_quad, zeros);
	for (int i = 0; i < 4; i++) angs[i] = ArcCosine(zeros[i]);
}

// Solve Quadric using Descartes' solution
void SolveQuadric(const float coeff[5], float zeros[4])
{
	// Divide through with coeff[4]
	float b4 = coeff[3]/coeff[4]; float c4 = coeff[2]/coeff[4]; float d4 = coeff[1]/coeff[4]; float e4 = coeff[0]/coeff[4];

	// x^4 + b*x^4 + c*x^2 + d*x + e -> y^2 + p*y^2 + q*y + r with x = y - b/4
	float p4 = 8*c4 - 3*P2(b4); float q4 = P3(b4) - 4*b4*c4 + 8*d4; float r4 = -3*P4(b4) + 256*e4 - 64*b4*d4 + 16*P2(b4)*c4;
	p4 = p4/8; q4 = q4/8; r4 = r4/256;

	// y^2 + p*y^2 + q*y + r = (y^2 + u*t + v)*(y^2 + s*y + t) -> U^3 + b*U^2 + c**U + d = 0 with U = u^2
	float b3 = 2*p4; float c3 = P2(p4) - 4*r4; float d3 = -P2(q4);

	// U^3 + b*U^2 + c**U + d = 0 -> T^3 + p*T + q = 0 with U = T - b/3
	float p3 = 3*c3 - P2(b3); float q3 = 2*P3(b3) - 9*b3*c3 + 27*d3;
	p3 = p3/3; q3 = q3/27;

	// Get a solution for T^3 + p*T + q = 0
	float m = -q3/2; float n = P2(q3/2) + P3(p3/3);
	n = n > 0 ? SquareRoot(n) : 0.0; // Sometimes it is under zero by a very small amount because of bad precision

	float T = (m + n > 0 ? Pow((m + n),1.0/3.0) : -Pow(-(m + n),1.0/3.0)) + (m - n > 0 ? Pow((m - n),1.0/3.0) : -Pow(-(m - n),1.0/3.0));
	float U = T - b3/3;

	float u = SquareRoot(U); float s = -u; float t = (p4 + U + q4/u)/2; float v = (p4 + U - q4/u)/2;


	float det_uv = P2(u) - 4*v;
	float det_st = P2(s) - 4*t;

	// More handling of precision errors since there always is a real solution in this plugin
	if (det_uv < 0 && det_uv + 0.0001 >= 0)
		det_uv = 0.0;

	if (det_st < 0 && det_st + 0.0001 >= 0)
		det_st = 0.0;

	//if (det_uv < 0.0 && det_st < 0.0) {
	//	if (det_uv > det_st) det_uv = 0.0;
	//	else det_st = 0.0;
	//}

	zeros[0] = (det_uv >= 0.0) ? (-u + SquareRoot(det_uv)) / 2.0 : NaN;
	zeros[1] = (det_uv >= 0.0) ? (-u - SquareRoot(det_uv)) / 2.0 : NaN;
	zeros[2] = (det_st >= 0.0) ? (-s + SquareRoot(det_st)) / 2.0 : NaN;
	zeros[3] = (det_st >= 0.0) ? (-s - SquareRoot(det_st)) / 2.0 : NaN;

	for (int i = 0; i < 4; i++) zeros[i] = zeros[i] - b4/4;
}

float FloatMin(float f1, float f2) { return (f1 < f2) ? f1 : f2; }
float FloatMax(float f1, float f2) { return (f1 > f2) ? f1 : f2; }
bool FloatIsNaN(float f) { return f != f; }
float P2(float f) { return f*f; }
float P3(float f) { return f*f*f; }
float P4(float f) { return f*f*f*f; }

void FloatString(float f, char[] buffer, int size)
{
	if (f - 0.005 < RoundToFloor(f) || f + 0.005 > RoundToCeil(f))
		FormatEx(buffer, size, "%d", RoundToNearest(f));
	else {
		FormatEx(buffer, size, "%.2f", float(RoundToNearest(f*100.0))/100.0 + 0.005);
	}
}

void CopyVector(const float[] vec, float[] buffer, int size=3)
{
	for (int i = 0; i < size; i++)
		buffer[i] = vec[i];
}

float NormVector(const float[] vec, float[] buffer=NULL_VECTOR, int size=3)
{
	float magnitude = SquareRoot(DotVectors(vec, vec, size));
	for (int i = 0; i < size; i++)
		buffer[i] = vec[i]/magnitude;
	return magnitude;
}

void OffsetVector(const float[] vec, const float[] dir, float scale, float[] buffer, int size=3)
{
	for (int i = 0; i < size; i++)
		buffer[i] = vec[i] + dir[i]*scale;
}

float DotVectors(const float[] vec1, const float[] vec2, int size=3)
{
	float dot = 0.0;
	for (int i = 0; i < size; i++)
		dot += vec1[i]*vec2[i];
	return dot;
}

float DotUnitVectors(const float[] vec1, const float[] vec2, int size=3)
{
	float mag2 = SquareRoot(DotVectors(vec1, vec1, size)*DotVectors(vec2, vec2, size));
	float dot = 0.0;
	for (int i = 0; i < size; i++)
		dot += vec1[i]*vec2[i]/mag2;
	return dot;
}

//float DirDistVectors(const float[] vec1, const float[] vec2, const float[] dir, int size=3)
//{
//	float distance = 0.0;
//	for (int i = 0; i < size; i++)
//		distance += (vec1[i] - vec2[i])*dir[i];
//	return distance;
//}

bool CompareVectors(const float[] vec1, const float[] vec2, int size=3, float error=EPSILON)
{
	for (int i = 0; i < size; i++)
		if (FloatAbs(vec1[i] - vec2[i]) >= error)
			return false;
	return true;
}

//bool CompareUnitVectors(const float[] vec1, const float[] vec2, int size=3, float error=EPSILON)
//{
//	float mag1 = SquareRoot(DotVectors(vec1, vec1, size));
//	float mag2 = SquareRoot(DotVectors(vec2, vec2, size));
//	bool equal = true;
//	for (int i = 0; i < size; i++)
//		if (FloatAbs(vec1[i]/mag1 - vec2[i]/mag2) >= error)
//			equal = false;
//	return equal;
//}

bool AreParallel(const float[] vec1, const float[] vec2, int size=3, float error=EPSILON)
{
	return FloatAbs(FloatAbs(DotUnitVectors(vec1, vec2, size)) - 1.0) < error;
}