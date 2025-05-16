#pragma semicolon 1
#pragma newdecls required

#include <clientprefs>
#include <closestpos>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <shavit/core>
#include <shavit/replay-playback>
#include <sourcemod>

#define COLORS_NUMBER 9

enum { //enum for colors same indexes as colors below
	Red, //for all colors structs, first 5 idxs are default, dont reorder them
	Orange,
	Green,
	Cyan,
	White,
	Yellow,
	Blue,
	Purple,
	Pink
};

char g_sColorStrs[][] = { //strings for colors at same indexes as colors below
	"Red",
	"Orange",
	"Green",
	"Cyan",
	"White",
	"Yellow",
	"Blue",
	"Purple",
	"Pink"
};

int g_iColorInts[][] = { //general colors
	{255, 0, 0},
	{255, 165, 0},
	{0, 255, 0},
	{0, 255, 255},
	{255, 255, 255},
	{255, 255, 0},
	{0, 0, 255},
	{128, 0, 128},
	{238, 0, 255}
};

#define SKIPFRAMES 5
#define SEC_AHEAD 7
#define SEC_UPDATE_DELAY 1.5

#define DUCKCOLOR 0
#define NODUCKCOLOR 1
#define LINECOLOR 2
#define ENABLED 3
#define FLATMODE 4
#define GHOSTMODE 5
#define TRACK_IDX 6
#define STYLE_IDX 7
#define CMD_NUM 8
#define EDIT_ELEMENT 9
#define EDIT_COLOR 10

#define SETTINGS_NUMBER 6

#define TE_TIME 1.0
#define TE_MIN 0.5
#define TE_MAX 0.5

#define ELEMENT_NUMBER 3

char g_sElementStrings[][] = {
	"Duck Box",
	"No Duck Box",
	"Line"
};

enum {
	DuckBox,
	NoDuckBox,
	Line
}

enum OSType
{
	OSUnknown = 0,
	OSWindows = 1,
	OSLinux   = 2
};

enum {
	GS_RACE  = 0,
	GS_ROUTE = 1,
	GS_GUIDE = 2
}

OSType gOSType;
EngineVersion gEngineVer;

int sprite;
ArrayList g_hReplayFrames[STYLE_LIMIT][TRACKS_SIZE];
ArrayList g_hReplayFrames_Guide[STYLE_LIMIT][TRACKS_SIZE];
int g_iReplayPreFrames[STYLE_LIMIT][TRACKS_SIZE];
ClosestPos g_hClosestPos[STYLE_LIMIT][TRACKS_SIZE];
ClosestPos g_hClosestPos_Guide[STYLE_LIMIT][TRACKS_SIZE];

int g_iIntCache[MAXPLAYERS + 1][11];
Cookie g_hSettings[SETTINGS_NUMBER];

int gTELimitData;
Address gTELimitAddress;

int gI_ClientPrevFrame[MAXPLAYERS + 1];
int gI_MaxRecaculateFrameDiff;
int gI_GuideFramesAhead;
int gI_Tickrate;

public Plugin myinfo = {
	name = "shavit-line-advanced",
	author = "enimmy / NekoGan",
	description = "Shows the WR route with a path on the ground. Use the command sm_line to toggle.",
	version = "0.4",
	url = "https://github.com/TeasOfficial/shavit-line-advanced"
};

public void OnPluginStart() {
	gI_Tickrate = RoundToNearest(1.0 / GetTickInterval());

	g_hSettings[DUCKCOLOR] = new Cookie("shavit_line_duckcolor", "", CookieAccess_Private);
	g_hSettings[NODUCKCOLOR] = new Cookie("shavit_line_noduckcolor", "", CookieAccess_Private);
	g_hSettings[LINECOLOR] = new Cookie("shavit_line_linecolor", "", CookieAccess_Private);
	g_hSettings[ENABLED] = new Cookie("shavit_line_enabled", "", CookieAccess_Private);
	g_hSettings[FLATMODE] = new Cookie("shavit_line_flatmode", "", CookieAccess_Private);
	g_hSettings[GHOSTMODE] = new Cookie("shavit_line_ghostmode", "", CookieAccess_Private);

	RegConsoleCmd("sm_line", LineCmd);

	GameData gconf = new GameData("shavit-line.games");
	gOSType = view_as<OSType>(GameConfGetOffset(gconf, "OSType"));
	if(gOSType == OSUnknown){
		SetFailState("Failed to get OS type. Make sure gamedata file is in gamedata folder, and you are using windows or linux. Your Current OS Type is %d", gOSType);
	}

	gEngineVer = GetEngineVersion();
	if(gEngineVer == Engine_CSS)
		BytePatchTELimit(gconf);

	bool shavitLoaded = LibraryExists("shavit-replay-playback");

	if(shavitLoaded) {
		Shavit_OnReplaysLoaded();
	}

	for(int i = 1; i <= MaxClients; i++) {
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}

		if(shavitLoaded) {
			UpdateTrackStyle(i);
		}

		if (AreClientCookiesCached(i)) {
			OnClientCookiesCached(i);
		}
	}
}

public void OnPluginEnd()
{
	if(gTELimitAddress == Address_Null)
		return;
	
	StoreToAddress(gTELimitAddress, gTELimitData, NumberType_Int8);
}

stock void BytePatchTELimit(Handle gconf)
{
	//TELimit
	gTELimitAddress = GameConfGetAddress(gconf, "TELimit");
	if(gTELimitAddress == Address_Null){
		SetFailState("Failed to get addres of \"TELimit\".");
	}
	
	gTELimitData = LoadFromAddress(gTELimitAddress, NumberType_Int8);
	
	if(gOSType == OSWindows)
		StoreToAddress(gTELimitAddress, 0xFF, NumberType_Int8);
	else if(gOSType == OSLinux)
		StoreToAddress(gTELimitAddress, 0x02, NumberType_Int8);
	else
		SetFailState("Failed to store addres of \"TELimit\".");
}

public void OnClientCookiesCached(int client) {
	char strCookie[256];

	for(int i = 0; i < SETTINGS_NUMBER; i++) {
		GetClientCookie(client, g_hSettings[i], strCookie, sizeof(strCookie));
		if(strCookie[0] == '\0') {
			PushDefaultSettings(client);
			break;
		}
		g_iIntCache[client][i] = StringToInt(strCookie);
	}

	UpdateTrackStyle(client);
}

public void Shavit_OnReplaysLoaded() {
	for(int style = 0; style < STYLE_LIMIT; style++) {
		for(int track = 0; track < TRACKS_SIZE; track++) {
			LoadReplay(style, track);
		}
	}
}

public void LoadReplay(int style, int track) {
	delete g_hClosestPos[style][track];
	delete g_hClosestPos_Guide[style][track];
	delete g_hReplayFrames[style][track];
	delete g_hReplayFrames_Guide[style][track];
	g_iReplayPreFrames[style][track] = 0;

	ArrayList list = Shavit_GetReplayFrames(style, track, true);
	g_hReplayFrames[style][track] = new ArrayList(sizeof(frame_t));
	g_hReplayFrames_Guide[style][track] = new ArrayList(sizeof(frame_t));
	g_iReplayPreFrames[style][track] = Shavit_GetReplayPreFrames(style, track);

	if(!list) {
		return;
	}

	frame_t aFrame;
	bool hitGround = false;

	for(int i = 0; i < list.Length; i++) {
		list.GetArray(i, aFrame, sizeof(frame_t));
		if(aFrame.flags & FL_ONGROUND && !hitGround) {
			hitGround = true;
		}
		else {
			hitGround = false;
		}

		g_hReplayFrames_Guide[style][track].PushArray(aFrame);

		if (hitGround || i % SKIPFRAMES == 0) {
			g_hReplayFrames[style][track].PushArray(aFrame);
		}
	}

	g_hClosestPos[style][track] = new ClosestPos(g_hReplayFrames[style][track], 0, 0, Shavit_GetReplayFrameCount(style, track));
	g_hClosestPos_Guide[style][track] = new ClosestPos(g_hReplayFrames_Guide[style][track], 0, 0, Shavit_GetReplayFrames(style, track).Length - Shavit_GetReplayPostFrames(style, track));
	delete list;
}

public void Shavit_OnStyleChanged(int client, int oldstyle, int newstyle, int track, bool manual) {
	g_iIntCache[client][TRACK_IDX] = track;
	g_iIntCache[client][STYLE_IDX] = newstyle;
}

public void Shavit_OnReplaySaved(int client, int style, float time, int jumps, int strafes, float sync, int track) {
    LoadReplay(style, track);
}

public void OnConfigsExecuted() {
	sprite = PrecacheModel("sprites/laserbeam.vmt");

	gI_MaxRecaculateFrameDiff = RoundToNearest(3.0 * gI_Tickrate);
	gI_GuideFramesAhead = RoundToNearest(1.5 * gI_Tickrate);
}

Action LineCmd(int client, int args) {
	if (!IsValidClient(client)) {
		return Plugin_Handled;
	}
	ShowToggleMenu(client);
	return Plugin_Handled;
}

void ShowToggleMenu(int client) {
	Menu menu = CreateMenu(LinesMenu_Callback);
	SetMenuTitle(menu, "｢ Shavit Line Advanced ｣");
	AddMenuItem(menu, "linetoggle", (g_iIntCache[client][ENABLED]) ? "[x] Enabled":"[ ] Enabled");
	AddMenuItem(menu, "flatmode", (g_iIntCache[client][FLATMODE]) ? "[x] Flat Mode":"[ ] Flat Mode");
	AddMenuItem(menu, "ghosttoggle", (g_iIntCache[client][GHOSTMODE]) ? "[x] Guide Mode":"[ ] Guide Mode");

	char sMessage[256];
	Shavit_GetStyleStrings(g_iIntCache[client][STYLE_IDX], sStyleName, sMessage, sizeof(sMessage));
	Format(sMessage, sizeof(sMessage), "Style: %s", sMessage);

	AddMenuItem(menu, "style", sMessage);
	AddMenuItem(menu, "colors", "Colors");
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}


public int LinesMenu_Callback (Menu menu, MenuAction action, int client, int option) {
	if (action == MenuAction_Select) {
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));

		if (StrEqual(info, "linetoggle")) {
			g_iIntCache[client][ENABLED] = !g_iIntCache[client][ENABLED];

			if(g_iIntCache[client][ENABLED]) {
				Shavit_PrintToChat(client, "Explanation in Console");
				PrintToConsole(client, "The boxes on the ground show the jump locations of the WR route on this servers replay for the style you are on.");
				PrintToConsole(client, "By default White Box = Uncrouched Jump | Pink Box = Crouched Jump");
				PrintToConsole(client, "You can change the colors under settings.");
			}

			PushCookies(client);
		}
		else if(StrEqual(info, "flatmode")) {
			if(g_iIntCache[client][GHOSTMODE]){
				Shavit_PrintToChat(client, "FlatMode disabled by GuideMode, please turn off GuideMode first!");
			}else{
				g_iIntCache[client][FLATMODE] = !g_iIntCache[client][FLATMODE];
			}
			PushCookies(client);
		}
		else if(StrEqual(info, "style")) {
			int style = g_iIntCache[client][STYLE_IDX] + 1;
			for(int i = style; i < STYLE_LIMIT; i++) {
				if(g_hReplayFrames[i][g_iIntCache[client][TRACK_IDX]].Length > 0) {
					style = i;
					break;
				} else if(i == STYLE_LIMIT - 1) {
					style = 0;
				}
			}
			g_iIntCache[client][STYLE_IDX] = style;
		}
		else if (StrEqual(info, "colors")) {
			ShowColorOptionsMenu(client);
			return 0;
		}else if (StrEqual(info, "ghosttoggle")) {
			g_iIntCache[client][GHOSTMODE] = !g_iIntCache[client][GHOSTMODE];
			
			if(g_iIntCache[client][GHOSTMODE]){
				Shavit_PrintToChat(client, "Guide mode can display the best recorded route in server.");
				if(g_iIntCache[client][FLATMODE]){
					Shavit_PrintToChat(client, "FlatMode automatic disabled by GuideMode");
					g_iIntCache[client][FLATMODE] = 0;
				}
			}
			PushCookies(client);
		}
		ShowToggleMenu(client);
	}
	else if (action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

void ShowColorOptionsMenu(int client) {
	Menu menu = CreateMenu(LinesColors_Callback);
	SetMenuTitle(menu, "Colors\n\n");

	char sMessage[256];
	Format(sMessage, sizeof(sMessage), "< Editing: %s >", g_sElementStrings[g_iIntCache[client][EDIT_ELEMENT]]);
	AddMenuItem(menu, "editbox", sMessage);

	Format(sMessage, sizeof(sMessage), "Color: %s", g_sColorStrs[g_iIntCache[client][g_iIntCache[client][EDIT_ELEMENT]]]);
	AddMenuItem(menu, "editcolor", sMessage);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int LinesColors_Callback(Menu menu, MenuAction action, int client, int option) {
	if (action == MenuAction_Select) {
		char info[32];
		GetMenuItem(menu, option, info, sizeof(info));

		if(StrEqual(info, "editbox")) {
			g_iIntCache[client][EDIT_ELEMENT]++;

			if(g_iIntCache[client][EDIT_ELEMENT] >= ELEMENT_NUMBER)
			{
				g_iIntCache[client][EDIT_ELEMENT] = 0;
			}
		}
		else if (StrEqual(info, "editcolor")) {
			g_iIntCache[client][EDIT_COLOR]++;

			if(g_iIntCache[client][EDIT_COLOR] >= COLORS_NUMBER)
			{
				g_iIntCache[client][EDIT_COLOR] = 0;
			}

			g_iIntCache[client][g_iIntCache[client][EDIT_ELEMENT]] = g_iIntCache[client][EDIT_COLOR];
			PushCookies(client);
		}
		ShowColorOptionsMenu(client);
	}
	else if (action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

void PushDefaultSettings(int client) {
	g_iIntCache[client][ENABLED] = 1;
	g_iIntCache[client][FLATMODE] = 0;
	g_iIntCache[client][DUCKCOLOR] = Red;
	g_iIntCache[client][NODUCKCOLOR] = Pink;
	g_iIntCache[client][LINECOLOR] = White;
	PushCookies(client);
	UpdateTrackStyle(client);
}

void PushCookies(int client) {
	for(int i = 0; i < SETTINGS_NUMBER; i++) {
		SetCookie(client, g_hSettings[i], g_iIntCache[client][i]);
	}
}

void SetCookie(int client, Cookie hCookie, int n) {
	char strCookie[64];
	IntToString(n, strCookie, sizeof(strCookie));
	SetClientCookie(client, hCookie, strCookie);
}

public void OnPlayerRunCmdPost(int client) {
	if (!IsValidClient(client) || !g_iIntCache[client][ENABLED]) {
		return;
	}

	int closeframeC;
	ArrayList list;
	int closeframe;

	float pos[3];
	GetClientAbsOrigin(client, pos);

	int closepos;

	if(!g_iIntCache[client][GHOSTMODE]){
		if ((++g_iIntCache[client][CMD_NUM] % 60) != 0) {
			return;
		}
		closeframeC = 30;
		list = g_hReplayFrames[g_iIntCache[client][STYLE_IDX]][g_iIntCache[client][TRACK_IDX]];
		closepos = g_hClosestPos[g_iIntCache[client][STYLE_IDX]][g_iIntCache[client][TRACK_IDX]].Find(pos);
		if(!closepos){
			return;
		}
	}else{
		closeframeC = 0;
		list = g_hReplayFrames_Guide[g_iIntCache[client][STYLE_IDX]][g_iIntCache[client][TRACK_IDX]];
		closepos = g_hClosestPos_Guide[g_iIntCache[client][STYLE_IDX]][g_iIntCache[client][TRACK_IDX]].Find(pos);
		
	}

	if(!closepos){
		return;
	}
	closeframe = max(0, closepos - closeframeC);

	g_iIntCache[client][CMD_NUM] = 0;
	if (list.Length == 0 || !list) {
		return;
	}

	int flags;

	if(g_iIntCache[client][GHOSTMODE]) {
		frame_t curFrame, prevFrame;

		if(closeframe == gI_ClientPrevFrame[client]){
			gI_ClientPrevFrame[client] = closeframe;
			return;
		}

		int closeframediff = closeframe - gI_ClientPrevFrame[client];

		if(Abs(closeframediff) > gI_MaxRecaculateFrameDiff){
			gI_ClientPrevFrame[client] = closeframe;
		}else if(closeframediff > 1){
			closeframe = gI_ClientPrevFrame[client] + 1;
		}

		gI_ClientPrevFrame[client] = closeframe;
		if(closeframediff < 0) return;
			
		int iMaxFrames;
		if(closeframediff < g_iReplayPreFrames[g_iIntCache[client][STYLE_IDX]][g_iIntCache[client][TRACK_IDX]]){
			iMaxFrames = closeframe + gI_GuideFramesAhead / 2;
		}else{
			iMaxFrames = closeframe + gI_GuideFramesAhead;
		}

		if(closeframe >= list.Length){
			return;
		}else if(iMaxFrames >= list.Length){
			iMaxFrames = list.Length - 2;
		}

		list.GetArray(iMaxFrames, curFrame, sizeof(frame_t));
		list.GetArray(iMaxFrames <= 0 ? 0 : iMaxFrames - 1, prevFrame, sizeof(frame_t));

		DrawBeam(client, prevFrame.pos, curFrame.pos, TE_TIME, TE_MIN, TE_MAX, g_iColorInts[g_iIntCache[client][LINECOLOR]], 0.0, 0);
		if((curFrame.flags & FL_ONGROUND) && !(prevFrame.flags & FL_ONGROUND)){
			DrawBox(client, prevFrame.pos, g_iColorInts[g_iIntCache[client][(prevFrame.flags & FL_DUCKING) ? DUCKCOLOR:NODUCKCOLOR]]);
		}
	}else{
		int endframe = min(list.Length, closeframe + 125);

		frame_t aFrame;
		list.GetArray(closeframe, aFrame, sizeof(frame_t));
		pos = aFrame.pos;
		bool firstFlatDraw = true;
		for(int i = closeframe; i < endframe; i++) {
			list.GetArray(i, aFrame, 8);
			aFrame.pos[2] += 2.5;
			if(aFrame.flags & FL_ONGROUND && !(flags & FL_ONGROUND)) {
				DrawBox(client, aFrame.pos, g_iColorInts[g_iIntCache[client][(flags & FL_DUCKING) ? DUCKCOLOR:NODUCKCOLOR]]);

				if(!firstFlatDraw) {
					DrawBeam(client, pos, aFrame.pos, TE_TIME, TE_MIN, TE_MAX, g_iColorInts[g_iIntCache[client][LINECOLOR]], 0.0, 0);
				}

				firstFlatDraw = false;
				pos = aFrame.pos;
			}

			if(!g_iIntCache[client][FLATMODE]) {
				DrawBeam(client, pos, aFrame.pos, TE_TIME, TE_MIN, TE_MAX, g_iColorInts[g_iIntCache[client][LINECOLOR]], 0.0, 0);
				pos = aFrame.pos;
			}

			flags = aFrame.flags;
		}
	}
	return;
}

float box_offset[4][2] = {
	{-10.0, 10.0},
	{10.0, 10.0},
	{-10.0, -10.0},
	{10.0, -10.0},
};

void DrawBox(int client, float pos[3], int color[3]) {
	float square[4][3];
	for (int z = 0; z < 4; z++) {
		square[z][0] = pos[0] + (box_offset[z][0]);
		square[z][1] = pos[1] + (box_offset[z][1]);
		square[z][2] = pos[2];
	}

	DrawBeam(client, square[0], square[1], TE_TIME, TE_MIN, TE_MAX, color, 0.0, 0);
	DrawBeam(client, square[0], square[2], TE_TIME, TE_MIN, TE_MAX, color, 0.0, 0);
	DrawBeam(client, square[2], square[3], TE_TIME, TE_MIN, TE_MAX, color, 0.0, 0);
	DrawBeam(client, square[1], square[3], TE_TIME, TE_MIN, TE_MAX, color, 0.0, 0);
}

void DrawBeam(int client, float startvec[3], float endvec[3], float life, float width, float endwidth, int color[3], float amplitude, int speed) {

	int sendColor[4];
	for(int i = 0; i < 3; i++) {
		sendColor[i] = color[i];
	}
	sendColor[3] = 255;

	TE_SetupBeamPoints(startvec, endvec, sprite, 0, 0, 66, life, width, endwidth, 0, amplitude, sendColor, speed);
	TE_SendToClient(client);
}

int min(int a, int b) {
	return a < b ? a : b;
}

int max(int a, int b) {
	return a > b ? a : b;
}

int Abs(int num) {
	return num > 0 ? num : -num;
}

void UpdateTrackStyle(int client) {
	g_iIntCache[client][TRACK_IDX] = Shavit_GetClientTrack(client);
	g_iIntCache[client][STYLE_IDX] = Shavit_GetBhopStyle(client);
}