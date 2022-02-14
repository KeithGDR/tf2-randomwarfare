/*****************************/
//Pragma
#pragma semicolon 1
#pragma newdecls required

/*****************************/
//Defines
#define PLUGIN_NAME "[TF2] Random Warfare"
#define PLUGIN_DESCRIPTION "A randomized gamemode in TF2."
#define PLUGIN_VERSION "1.0.0"

/*****************************/
//Includes
#include <sourcemod>

#include <misc-sm>
#include <misc-tf>
#include <misc-colors>

#include <tf2items>
#include <tf_econ_data>

/*****************************/
//ConVars
ConVar convar_SwitchIntervals;
ConVar convar_OverrideClass;
ConVar convar_DefaultBuildingLevel_Sentry;
ConVar convar_DefaultBuildingLevel_Dispenser;
ConVar convar_DefaultBuildingLevel_Teleporters;

/*****************************/
//Globals
//bool g_Late;

ArrayList g_Whitelist;

Handle g_Timer_Randomize[MAXPLAYERS + 1];
int g_Countdown[MAXPLAYERS + 1];
Handle g_Sync_Countdown;

ArrayList g_Items_Scout;
ArrayList g_Items_Soldier;
ArrayList g_Items_Pyro;
ArrayList g_Items_Demoman;
ArrayList g_Items_Heavy;
ArrayList g_Items_Engineer;
ArrayList g_Items_Medic;
ArrayList g_Items_Sniper;
ArrayList g_Items_Spy;

bool g_ShowMenu[MAXPLAYERS + 1];

enum
{
	OBJ_DISPENSER,
	OBJ_TELEPORTER,
	OBJ_SENTRY
}

Handle g_hSDKStartBuilding;
Handle g_hSDKFinishBuilding;
Handle g_hSDKStartUpgrading;
Handle g_hSDKFinishUpgrading;

/*****************************/
//Plugin Info
public Plugin myinfo = 
{
	name = PLUGIN_NAME, 
	author = "Drixevel", 
	description = PLUGIN_DESCRIPTION, 
	version = PLUGIN_VERSION, 
	url = "https://drixevel.dev/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	//g_Late = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	convar_SwitchIntervals = CreateConVar("sm_randomwarfare_switch_intervals", "4-6");
	convar_OverrideClass = CreateConVar("sm_randomwarfare_overrideclass", "-1");
	convar_DefaultBuildingLevel_Sentry = CreateConVar("sm_randomwarfare_default_sentry_level", "2");
	convar_DefaultBuildingLevel_Dispenser = CreateConVar("sm_randomwarfare_default_dispenser_level", "3");
	convar_DefaultBuildingLevel_Teleporters = CreateConVar("sm_randomwarfare_default_teleporter_level", "3");

	g_Whitelist = new ArrayList();

	RegConsoleCmd("sm_gamemode", Command_Gamemode, "Shows the details for the gamemode.");

	RegAdminCmd("sm_allowweapon", Command_AllowWeapon, ADMFLAG_ROOT);
	RegAdminCmd("sm_denyweapon", Command_DenyWeapon, ADMFLAG_ROOT);
	
	g_Sync_Countdown = CreateHudSynchronizer();
	
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i))
			TF2_RespawnPlayer(i);
	
	FindConVar("tf_cheapobjects").SetInt(1);
	HookEvent("player_builtobject", Event_OnObjectBuild);
	
	char sFilePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFilePath, sizeof(sFilePath), "gamedata/buildings.txt");
	
	if (FileExists(sFilePath))
	{
		Handle hGameConf = LoadGameConfigFile("buildings");
		
		if (hGameConf != null )
		{
			StartPrepSDKCall(SDKCall_Entity);
			PrepSDKCall_SetFromConf(hGameConf, SDKConf_Virtual, "CBaseObject::StartBuilding");
			g_hSDKStartBuilding = EndPrepSDKCall();

			StartPrepSDKCall(SDKCall_Entity);
			PrepSDKCall_SetFromConf(hGameConf, SDKConf_Virtual, "CBaseObject::FinishedBuilding");
			g_hSDKFinishBuilding = EndPrepSDKCall();

			StartPrepSDKCall(SDKCall_Entity);
			PrepSDKCall_SetFromConf(hGameConf, SDKConf_Virtual, "CBaseObject::StartUpgrading");
			g_hSDKStartUpgrading = EndPrepSDKCall();
			
			StartPrepSDKCall(SDKCall_Entity);
			PrepSDKCall_SetFromConf(hGameConf, SDKConf_Virtual, "CBaseObject::FinishUpgrading");
			g_hSDKFinishUpgrading = EndPrepSDKCall();
			
			delete hGameConf;
		}

		if (g_hSDKStartBuilding == null || g_hSDKFinishBuilding == null || g_hSDKStartUpgrading == null || g_hSDKFinishUpgrading == null)
			LogError("Failed to load gamedata/buildings.txt. Instant building and upgrades will not be available.");
	}
}

public Action Command_AllowWeapon(int client, int args)
{
	int defindex = GetCmdArgInt(1);

	if (g_Whitelist.FindValue(defindex) != -1)
	{
		CPrintToChat(client, "Index '%i' is already whitelisted.", defindex);
		return Plugin_Handled;
	}

	g_Whitelist.Push(defindex);
	CPrintToChat(client, "Index '%i' is now whitelisted.", defindex);
	SaveWhitelistData(defindex, true);

	return Plugin_Handled;
}

public Action Command_DenyWeapon(int client, int args)
{
	int defindex = GetCmdArgInt(1);
	int index = g_Whitelist.FindValue(defindex);

	if (index == -1)
	{
		CPrintToChat(client, "Index '%i' is not currently whitelisted.", defindex);
		return Plugin_Handled;
	}

	g_Whitelist.Erase(index);
	CPrintToChat(client, "Index '%i' is now de-whitelisted.", defindex);
	SaveWhitelistData(defindex, false);
	
	return Plugin_Handled;
}

void SaveWhitelistData(int defindex, bool allow)
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/randomwarfare.cfg");

	char sIndex[16];
	IntToString(defindex, sIndex, sizeof(sIndex));

	KeyValues kv = new KeyValues("randomwarfare");
	kv.ImportFromFile(sPath);
	kv.SetNum(sIndex, allow);
	kv.Rewind();
	kv.ExportToFile(sPath);
	delete kv;

	ParseAllowedWeapons();
}

public void OnMapStart()
{
	PrecacheSound("ui/hint.wav");
	PrecacheSound("items/gunpickup2.wav");
}

public void OnAllPluginsLoaded()
{
	ParseAllowedWeapons();
}

void ParseAllowedWeapons()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/randomwarfare.cfg");

	KeyValues kv = new KeyValues("randomwarfare");

	if (kv.ImportFromFile(sPath) && kv.GotoFirstSubKey(false))
	{
		g_Whitelist.Clear();

		char sDefIndex[32];
		do
		{
			kv.GetSectionName(sDefIndex, sizeof(sDefIndex));

			if (kv.GetNum(NULL_STRING) > 0)
				g_Whitelist.Push(StringToInt(sDefIndex));
		}
		while (kv.GotoNextKey(false));
	}

	delete kv;

	delete g_Items_Scout;
	g_Items_Scout = TF2Econ_GetItemList(onParseItems, TFClass_Scout);
	
	delete g_Items_Soldier;
	g_Items_Soldier = TF2Econ_GetItemList(onParseItems, TFClass_Soldier);

	delete g_Items_Pyro;
	g_Items_Pyro = TF2Econ_GetItemList(onParseItems, TFClass_Pyro);

	delete g_Items_Demoman;
	g_Items_Demoman = TF2Econ_GetItemList(onParseItems, TFClass_DemoMan);

	delete g_Items_Heavy;
	g_Items_Heavy = TF2Econ_GetItemList(onParseItems, TFClass_Heavy);

	delete g_Items_Engineer;
	g_Items_Engineer = TF2Econ_GetItemList(onParseItems, TFClass_Engineer);

	delete g_Items_Medic;
	g_Items_Medic = TF2Econ_GetItemList(onParseItems, TFClass_Medic);

	delete g_Items_Sniper;
	g_Items_Sniper = TF2Econ_GetItemList(onParseItems, TFClass_Sniper);

	delete g_Items_Spy;
	g_Items_Spy = TF2Econ_GetItemList(onParseItems, TFClass_Spy);
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i))
			ClearSyncHud(i, g_Sync_Countdown);
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		StopTimer(g_Timer_Randomize[i]);
}

public void OnClientConnected(int client)
{
	g_ShowMenu[client] = true;
}

public void TF2_OnPlayerSpawn(int client)
{
	g_Countdown[client] = GetConVarRandom(convar_SwitchIntervals);
	
	if (!IsFakeClient(client))
	{
		SetHudTextParams(-1.0, 0.1, 99999.0, 255, 0, 0, 255);
		ShowSyncHudText(client, g_Sync_Countdown, "Switching in %i", g_Countdown[client]);
	}
			
	StopTimer(g_Timer_Randomize[client]);
	g_Timer_Randomize[client] = CreateTimer(1.0, Timer_Randomize, client, TIMER_REPEAT);
	
	if (g_ShowMenu[client] && IsClientInGame(client) && IsPlayerAlive(client))
	{
		g_ShowMenu[client] = false;
		CreateTimer(2.0, Timer_ShowPanel, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
	
	RequestFrame(Frame_Randomize, GetClientUserId(client));
}

public void Frame_Randomize(any data)
{
	int client = GetClientOfUserId(data);

	if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
		RandomizePlayer(client);
}

public Action Command_Gamemode(int client, int args)
{
	Timer_ShowPanel(null, GetClientUserId(client));
	return Plugin_Handled;
}

public Action Timer_ShowPanel(Handle timer, any data)
{
	int client;
	if ((client = GetClientOfUserId(data)) > 0 && IsClientConnected(client) && IsClientInGame(client) && IsPlayerAlive(client))
	{
		Panel panel = new Panel();
		panel.SetTitle("TF2 - Random Warfare (Gamemode)\n \n");
		panel.DrawText(" * Your class automatically changes every 4-6 seconds.");
		panel.DrawText(" * Engineer buildings are automatic placement.");
		panel.DrawText(" * Sentries self detonate but other buildings remain for 15 seconds.");
		panel.DrawText(" * Medics automatically have 100% Ubercharge on switch.");
		panel.DrawText(" * Demoknights will automatically have 100 heads available.");
		panel.DrawText(" * All Soldier banner type weapons have 100% charge.");
		panel.DrawText(" * Snipers have 100% charge on zoom-in.\n ");
		panel.DrawItem("Close Panel");
		panel.Send(client, MenuHandler_Panel, MENU_TIME_FOREVER);
		delete panel;
	}
}

public int MenuHandler_Panel(Menu menu, MenuAction action, int param1, int param2)
{
	
}

public void TF2_OnPlayerDeath(int client, int attacker, int assister, int inflictor, int damagebits, int stun_flags, int death_flags, int customkill)
{
	if ((death_flags & TF_DEATHFLAG_DEADRINGER) == TF_DEATHFLAG_DEADRINGER)
		return;
	
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "obj_*")) != -1)
		if (GetEntPropEnt(entity, Prop_Send, "m_hBuilder") == client)
			SDKHooks_TakeDamage(entity, 0, 0, 99999.0);
	
	StopTimer(g_Timer_Randomize[client]);
}

public Action Timer_Randomize(Handle timer, any data)
{
	int client = data;
	
	if (!IsClientInGame(client))
	{
		g_Timer_Randomize[client] = null;
		return Plugin_Stop;
	}
	
	if (g_Countdown[client] > 1)
	{
		g_Countdown[client]--;
		
		if (!IsFakeClient(client))
		{
			SetHudTextParams(-1.0, 0.1, 99999.0, 255, 0, 0, 255);
			ShowSyncHudText(client, g_Sync_Countdown, "Switching in %i", g_Countdown[client]);
			
			if (g_Countdown[client] < 3)
				EmitSoundToClient(client, "ui/hint.wav");
		}
		
		return Plugin_Continue;
	}
	
	RandomizePlayer(client);
	
	return Plugin_Continue;
}

void RandomizePlayer(int client)
{
	bool bleeding = TF2_IsPlayerInCondition(client, TFCond_Bleeding);
	bool jarated = TF2_IsPlayerInCondition(client, TFCond_Jarated);
	bool milked = TF2_IsPlayerInCondition(client, TFCond_Milked);
	bool gas = TF2_IsPlayerInCondition(client, TFCond_Gas);
	
	g_Countdown[client] = GetConVarRandom(convar_SwitchIntervals);
	
	if (!IsFakeClient(client))
	{
		SetHudTextParams(-1.0, 0.1, 99999.0, 255, 0, 0, 255);
		ShowSyncHudText(client, g_Sync_Countdown, "Switching in %i", g_Countdown[client]);
	}
	
	TFClassType class = view_as<TFClassType>(GetRandomInt(1, 9));

	if (convar_OverrideClass.IntValue != -1)
		class = view_as<TFClassType>(convar_OverrideClass.IntValue);
	
	ArrayList items;
	switch (class)
	{
		case TFClass_Scout: items = g_Items_Scout;
		case TFClass_Soldier: items = g_Items_Soldier;
		case TFClass_Pyro: items = g_Items_Pyro;
		case TFClass_DemoMan: items = g_Items_Demoman;
		case TFClass_Heavy: items = g_Items_Heavy;
		case TFClass_Engineer: items = g_Items_Engineer;
		case TFClass_Medic: items = g_Items_Medic;
		case TFClass_Sniper: items = g_Items_Sniper;
		case TFClass_Spy: items = g_Items_Spy;
	}
		
	int health = GetClientHealth(client);
	
	if (TF2_GetPlayerClass(client) != class)
		TF2_SetPlayerClass(client, class, false, false);
	
	TF2_RegeneratePlayer(client);
	
	char sPrimary[64]; //char sPrimaryD[64];
	int primary = GetRandomWeapon(items, class == TFClass_Spy ? TFWeaponSlot_Secondary : TFWeaponSlot_Primary, class, sPrimary, sizeof(sPrimary));
	
	char sSecondary[64]; //char sSecondaryD[64];
	int secondary = GetRandomWeapon(items, TFWeaponSlot_Secondary, class, sSecondary, sizeof(sSecondary));
	
	char sMelee[64]; //char sMeleeD[64];
	int melee = GetRandomWeapon(items, TFWeaponSlot_Melee, class, sMelee, sizeof(sMelee));
	
	if (primary == -1 || secondary == -1 || melee == -1)
		return;
	
	TF2_RemoveWeaponSlot(client, TFWeaponSlot_Primary);
	TF2_RemoveWeaponSlot(client, TFWeaponSlot_Secondary);
	TF2_RemoveWeaponSlot(client, TFWeaponSlot_Melee);

	SetEntityHealth(client, health);
	EmitSoundToClient(client, "items/gunpickup2.wav");
	
	DataPack pack;
	CreateDataTimer(0.2, Frame_Equip, pack, TIMER_FLAG_NO_MAPCHANGE);
	pack.WriteCell(GetClientUserId(client));
	pack.WriteString(sPrimary);
	pack.WriteCell(primary);
	pack.WriteString(sSecondary);
	pack.WriteCell(secondary);
	pack.WriteString(sMelee);
	pack.WriteCell(melee);
	
	if (class == TFClass_Medic)
		CreateTimer(0.5, Timer_SetUber, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	else if (class == TFClass_DemoMan)
		SetEntProp(client, Prop_Send, "m_iDecapitations", 100);
	
	if (GetEntProp(client, Prop_Send, "m_bCarryingObject"))
	{
		int obj = GetEntPropEnt(client, Prop_Send, "m_hCarriedObject");
		if (IsValidEntity(obj))
			AcceptEntityInput(obj, "Kill");
	}
	
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "obj_*")) != -1)
	{
		if (GetEntPropEnt(entity, Prop_Send, "m_hBuilder") != client)
			continue;
		
		if (IsClassname(entity, "obj_sentrygun"))
			SDKHooks_TakeDamage(entity, 0, 0, 99999.0);
		else
			CreateTimer(15.0, Timer_DestroyBuilding, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
	}
	
	if (TF2_IsPlayerInCondition(client, TFCond_Taunting))
		TF2_RemoveCondition(client, TFCond_Taunting);
	
	if (bleeding)
		TF2_AddCondition(client, TFCond_Bleeding, 2.0);
	
	if (jarated)
		TF2_AddCondition(client, TFCond_Jarated, 2.0);
	
	if (milked)
		TF2_AddCondition(client, TFCond_Milked, 2.0);
	
	if (gas)
		TF2_AddCondition(client, TFCond_Gas, 2.0);
}

public Action Timer_DestroyBuilding(Handle timer, any data)
{
	int entity = EntRefToEntIndex(data);
	
	if (IsValidEntity(entity))
		SDKHooks_TakeDamage(entity, 0, 0, 99999.0);
}

public Action Timer_SetUber(Handle timer, any data)
{
	int client = GetClientOfUserId(data);
	
	if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
		TF2_SetUberLevel(client, 1.0);
}

public Action Frame_Equip(Handle timer, DataPack pack)
{
	pack.Reset();
	
	int client = GetClientOfUserId(pack.ReadCell());
	
	//primary
	char sPrimary[64];
	pack.ReadString(sPrimary, sizeof(sPrimary));
	
	int primary = pack.ReadCell();
	
	//secondary
	char sSecondary[64];
	pack.ReadString(sSecondary, sizeof(sSecondary));
	
	int secondary = pack.ReadCell();
	
	//melee
	char sMelee[64];
	pack.ReadString(sMelee, sizeof(sMelee));
	
	int melee = pack.ReadCell();
	
	if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
	{
		if (primary != -1)
			TF2_GiveItem(client, sPrimary, primary);
		
		if (secondary != -1)
		{
			int weapon = TF2_GiveItem(client, sSecondary, secondary);
			
			int index = GetWeaponIndex(weapon);
			if (index == 129 || index == 226 || index == 354 || index == 1001 || index == 594)
				TF2_SetRageMeter(client, 100.0);
		}
		
		if (melee != -1)
			TF2_GiveItem(client, sMelee, melee);
	}
}

int GetRandomWeapon(ArrayList items, int slot, TFClassType class, char[] buffer, int size)
{
	ArrayList possibles = new ArrayList();
	
	int defindex;
	for (int i = 0; i < items.Length; i++)
	{
		defindex = items.Get(i);
		
		if (!TF2Econ_IsValidItemDefinition(defindex) || TF2Econ_GetItemSlot(defindex, class) != slot)
			continue;
		
		possibles.Push(defindex);
	}
	
	if (possibles.Length < 1)
	{
		delete possibles;
		return -1;
	}
	
	defindex = possibles.Get(GetRandomInt(0, possibles.Length - 1));
	delete possibles;
	
	TF2Econ_GetItemClassName(defindex, buffer, size);
	
	if (StrContains(buffer, "saxxy", false) != -1)
	{
		switch (class)
		{
			case TFClass_Scout: strcopy(buffer, size, "tf_weapon_bat");
			case TFClass_Sniper: strcopy(buffer, size, "tf_weapon_club");
			case TFClass_Soldier: strcopy(buffer, size, "tf_weapon_shovel");
			case TFClass_DemoMan: strcopy(buffer, size, "tf_weapon_bottle");
			case TFClass_Engineer: strcopy(buffer, size, "tf_weapon_wrench");
			case TFClass_Pyro: strcopy(buffer, size, "tf_weapon_fireaxe");
			case TFClass_Heavy: strcopy(buffer, size, "tf_weapon_fists");
			case TFClass_Spy: strcopy(buffer, size, "tf_weapon_knife");
			case TFClass_Medic: strcopy(buffer, size, "tf_weapon_bonesaw");
		}
	}
	else if (StrContains(buffer, "shotgun", false) != -1)
	{
		switch (class)
		{
			case TFClass_Soldier: strcopy(buffer, size, "tf_weapon_shotgun_soldier");
			case TFClass_Engineer: strcopy(buffer, size, "tf_weapon_shotgun_primary");
			case TFClass_Pyro: strcopy(buffer, size, "tf_weapon_shotgun_pyro");
			case TFClass_Heavy: strcopy(buffer, size, "tf_weapon_shotgun_hwg");
		}
	}
	else if (StrContains(buffer, "tf_weapon", false) != 0)
		return -1;
	
	return defindex;
}

public bool onParseItems(int defindex, TFClassType class)
{
	if (g_Whitelist.FindValue(defindex) == -1)
		return false;
	
	return TF2Econ_GetItemSlot(defindex, class) != -1;
}

public void TF2_OnRoundEnd(int team, int winreason, int flagcaplimit, bool full_round, float round_time, int losing_team_num_caps, bool was_sudden_death)
{
	for (int i = 1; i <= MaxClients; i++)
		StopTimer(g_Timer_Randomize[i]);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity > 0 && StrContains(classname, "tf_dropped", false) != -1)
		AcceptEntityInput(entity, "Kill");
}

public void OnClientDisconnect(int client)
{
	StopTimer(g_Timer_Randomize[client]);
}

public void TF2_OnZoomIn(int client)
{
	int active = GetActiveWeapon(client);

	if (IsValidEntity(active))
		TF2_SetSniperRifleCharge(active, 100.0);
}

public void Event_OnObjectBuild(Event event, const char[] name, bool dontBroadcast)
{
	int obj = event.GetInt("object");
	int index = event.GetInt("index");
	
	if (g_hSDKStartBuilding == null || g_hSDKFinishBuilding == null || g_hSDKStartUpgrading == null || g_hSDKFinishUpgrading == null)
		return;
		
	RequestFrame(FrameCallback_StartBuilding, index);
	RequestFrame(FrameCallback_FinishBuilding, index);

	switch (obj)
	{
		case OBJ_DISPENSER:
		{
			SetEntProp(index, Prop_Send, "m_iUpgradeLevel", convar_DefaultBuildingLevel_Dispenser.IntValue - 1);
			SetEntProp(index, Prop_Send, "m_iHighestUpgradeLevel", convar_DefaultBuildingLevel_Dispenser.IntValue - 1);
			RequestFrame(FrameCallback_StartUpgrading, index);
			RequestFrame(FrameCallback_FinishUpgrading, index);
		}
		case OBJ_TELEPORTER:
		{
			SetEntProp(index, Prop_Send, "m_iUpgradeLevel", convar_DefaultBuildingLevel_Teleporters.IntValue - 1);
			SetEntProp(index, Prop_Send, "m_iHighestUpgradeLevel", convar_DefaultBuildingLevel_Teleporters.IntValue - 1);
			RequestFrame(FrameCallback_StartUpgrading, index);
			RequestFrame(FrameCallback_FinishUpgrading, index);
			
			SetEntProp(index, Prop_Send, "m_CollisionGroup", 2);
		}
		case OBJ_SENTRY:
		{
			int mini = GetEntProp(index, Prop_Send, "m_bMiniBuilding");
			
			if (mini == 1)
				return;
			
			SetEntProp(index, Prop_Send, "m_iUpgradeLevel", convar_DefaultBuildingLevel_Sentry.IntValue - 1);
			SetEntProp(index, Prop_Send, "m_iHighestUpgradeLevel", convar_DefaultBuildingLevel_Sentry.IntValue - 1);
			RequestFrame(FrameCallback_StartUpgrading, index);
			RequestFrame(FrameCallback_FinishUpgrading, index);
		}
	}

	SetEntProp(index, Prop_Send, "m_iUpgradeMetalRequired", 99999);

	SetVariantInt(GetEntProp(index, Prop_Data, "m_iMaxHealth"));
	AcceptEntityInput(index, "SetHealth");
}

public void FrameCallback_StartBuilding(any entity)
{
	SDKCall(g_hSDKStartBuilding, entity);
}

public void FrameCallback_FinishBuilding(any entity)
{
	SDKCall(g_hSDKFinishBuilding, entity);
}

public void FrameCallback_StartUpgrading(any entity)
{
	SDKCall(g_hSDKStartUpgrading, entity);
}

public void FrameCallback_FinishUpgrading(any entity)
{
	SDKCall(g_hSDKFinishUpgrading, entity);
}