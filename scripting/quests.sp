#include <sourcemod>
#include <lvl_ranks>
#include <sdktools>
#include <cstrike>
#include <shop>

#pragma newdecls required
#pragma semicolon 1

//#define DEBUG

#define PREFIX " \x04[Quests]\x01"

#define PROGRESS_CHAR_PROGRESS "█"// ▓
#define PROGRESS_CHAR_REMAINING "▒"

// Database
Database g_Database;

// The sound that will play once the player has completed a quest.
char g_QuestCompleteSound[PLATFORM_MAX_PATH];

// Number of quests to give every day.
int g_DailyQuestAmount;

enum struct QuestCondition
{
	// field to check
	char field[32];
	
	// value it must match. (or the special checkers: <team-t> / <team-ct>)
	char value[32];
}

enum struct Quest
{
	// Event name to show in the menu and when printing to chat.
	char display_name[64];
	
	// Event Name and the user field to advance his progress
	char event_name[32];
	char userid_field[32];
	
	// Amount of times to achieve the quest to mark it as completed.
	int times_to_achieve;
	
	// Rewards to give upon quest completion.
	int reward_xp;
	int reward_credits;
	
	// Conditions for the event
	ArrayList conditions;
	
	void Init()
	{
		this.conditions = new ArrayList(sizeof(QuestCondition));
	}
	
	void HookQuestEvent(EventHook callback, EventHookMode mode = EventHookMode_Post)
	{
		if (this.event_name[0])
		{
			HookEventEx(this.event_name, callback, mode);
			LogMessage("Hooked '%s' Quest Event: %s", this.display_name, this.event_name);
		}
	}
	
	void Close(bool unhook_event = false)
	{
		delete this.conditions;
	}
}
ArrayList g_Quests;

enum struct QuestProgress
{
	// index in the global ArrayList
	int index;
	
	// Progress of quest
	int progress;
}
ArrayList g_QuestsProgress[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "Daily Quests", 
	author = "Natanel 'LuqS'", 
	description = "", 
	version = "1.0.0", 
	url = "https://steamcommunity.com/id/luqsgood || Discord: LuqS#6505"
};

public void OnPluginStart()
{
	if (GetEngineVersion() != Engine_CSGO)
	{
		SetFailState("This plugin is for CSGO only.");
	}
	
	// Load Quests
	LoadQuests();
	
	// Reload Quests in 00:00
	CreateTimer(float(86400 - (GetTime() % 86400)), ReloadQuests);
	
	// Connect to the database
	Database.Connect(Database_OnConnection, "Quests");
	
	// Commands
	RegConsoleCmd("sm_quest", Command_Quests);
	RegConsoleCmd("sm_quests", Command_Quests);
	
	RegServerCmd("sm_print_loaded_quests", Command_PrintQuests);
	//RegConsoleCmd("sm_print_my_quests", Command_PrintClientQuests);

	if (Shop_IsStarted())
	{
		Shop_Started();
	}
}

public void OnPluginEnd()
{
	RemoveFunctionFromShop();
	
	// Early unload
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientAuthorized(current_client) && !IsFakeClient(current_client))
		{
			OnClientDisconnect(current_client);
		}
	}
}

public void OnMapStart()
{
	if (g_QuestCompleteSound[0])
	{
		AddFileToDownloadsTable(g_QuestCompleteSound);
		PrecacheSound(g_QuestCompleteSound[6], true);
	}
}

public void OnClientPostAdminCheck(int client)
{
	if (!IsFakeClient(client))
	{
		LoadPlayerQuests(client);
	}
}

public void OnClientDisconnect(int client)
{
	if (!g_QuestsProgress[client])
	{
		// ???
		return;
	}
	
	int client_account_id = GetSteamAccountID(client);
	
	char quest_name[64], query[256];
	QuestProgress current_progress_data;
	for (int current_quest = 0; current_quest < g_QuestsProgress[client].Length; current_quest++)
	{
		// Get client quest progress data
		g_QuestsProgress[client].GetArray(current_quest, current_progress_data);
		
		// Get quest name
		g_Quests.GetString(current_progress_data.index, quest_name, sizeof(quest_name));
		
		// insert to database
		g_Database.Format(query, sizeof(query), "REPLACE INTO `quests_progress` (`accountid`, `quest`, `progress`) VALUES (%u, '%s', %d)", client_account_id, quest_name, current_progress_data.progress);
		/*
		g_Database.Format(query, sizeof(query), "INSERT INTO `quests_progress` (`accountid`, `quest`, `progress`) VALUES (%u, '%s', %d) \
												ON DUPLICATE KEY UPDATE `progress`=VALUES(`progress`)", client_account_id, quest_name, current_progress_data.progress);
		*/
		
		#if defined DEBUG
		LogMessage("[OnClientDisconnect] Query: %s", query);
		#endif
		
		g_Database.Query(Database_FakeFastQuery, query);
	}
	
	delete g_QuestsProgress[client];
}

void OnQuestEvent(Event event, const char[] name, bool dont_broadcast)
{
	// Check if there are not enough people on the server right now.
	#if defined DEBUG
	if (false)
	#else
	if (!LR_CheckCountPlayers())
	#endif
	{
		return;
	}
	
	QuestProgress client_quest_progress;
	Quest current_quest_data;
	for (int current_quest = 0, num_of_quests = g_Quests.Length; current_quest < num_of_quests; current_quest++)
	{
		g_Quests.GetArray(current_quest, current_quest_data);
		
		// Check if the quest needs this event
		if (!StrEqual(current_quest_data.event_name, name, false))
		{
			continue;
		}
		
		int client = GetClientOfUserId(event.GetInt(current_quest_data.userid_field));
		
		// Invalid userid or bot
		if (!client || IsFakeClient(client))
		{
			continue;
		}
		
		// Client quests not initialized yet
		if (!g_QuestsProgress[client])
		{
			return;
		}

		int client_quest_index = g_QuestsProgress[client].FindValue(current_quest, QuestProgress::index);
		
		// If the player doesn't have this quest, don't bother checking the conditions.
		if (client_quest_index == -1)
		{
			continue;
		}
		
		g_QuestsProgress[client].GetArray(client_quest_index, client_quest_progress);
		
		// Player already finished this quest, don't continue.
		if (client_quest_progress.progress == current_quest_data.times_to_achieve)
		{
			continue;
		}
		
		// Make sure conditions Array-List is valid.
		if (current_quest_data.conditions)
		{
			bool conditions_failed;
			char event_condition_value[32];
			QuestCondition current_condition_data;
			
			for (int current_condition = 0; current_condition < current_quest_data.conditions.Length; current_condition++)
			{
				current_quest_data.conditions.GetArray(current_condition, current_condition_data);
				
				
				if (IsSpecialFieldOrValue(current_condition_data.value, sizeof(QuestCondition::value)))
				{
					// check special conditions
					if (StrEqual(current_condition_data.value, "t", false) || StrEqual(current_condition_data.value, "ct", false))
					{
						int player_to_check = GetClientOfUserId(event.GetInt(current_condition_data.field));
						
						if (!player_to_check || GetClientTeam(player_to_check) != (current_condition_data.value[0] == 'c' ? CS_TEAM_CT : CS_TEAM_T))
						{
							conditions_failed = true;
							break;
						}
					}
					
					continue;
				}
				
				event.GetString(current_condition_data.field, event_condition_value, sizeof(event_condition_value));
				
				// Check 'current_condition_data.field' for special field '<time>'.
				if (IsSpecialFieldOrValue(current_condition_data.field, sizeof(QuestCondition::field)))
				{
					if (StrEqual(current_condition_data.field, "time", false))
					{
						if (GetClientTime(client) / 60.0 < StringToFloat(current_condition_data.value))
						{
							conditions_failed = true;
							break;
						}
					}
					
					continue;
				}
				
				if (!StrEqual(event_condition_value, current_condition_data.value))
				{
					conditions_failed = true;
					break;
				}
			}
			
			if (conditions_failed)
			{
				continue;
			}
		}
		
		// Check if the player finished his quest.
		if (++client_quest_progress.progress == current_quest_data.times_to_achieve)
		{
			// Give XP
			if (current_quest_data.reward_xp && LR_ChangeClientValue(client, current_quest_data.reward_xp))
			{
				LR_PrintToChat(client, true, "Your exp: {GREEN}%d [+%d for completing a quest {OLIVE}%s{GREEN}]", LR_GetClientInfo(client, ST_EXP), current_quest_data.reward_xp, current_quest_data.display_name);
			}
			
			// Give Credits
			if (current_quest_data.reward_credits)
			{
				LR_PrintToChat(client, true, "Your credits: {GREEN}%d [+%d for completing a quest {OLIVE}%s{GREEN}]", Shop_GiveClientCredits(client, current_quest_data.reward_credits), current_quest_data.reward_credits, current_quest_data.display_name);
			}
			
			// Emit sound
			if (g_QuestCompleteSound[0])
			{
				EmitSoundToClient(client, g_QuestCompleteSound[6]);
			}
			
			// Show HUD message
			ShowPanel2(client, 6, "<font class='fontSize-l'><span color=\"#bfff00;\">Q</span><span color=\"#c3ef00;\">u</span><span color=\"#c7df00;\">e</span><span color=\"#cbcf00;\">s</span><span color=\"#cfbf00;\">t</span> <span color=\"#d79f00;\">C</span><span color=\"#db8f00;\">o</span><span color=\"#df7f00;\">m</span><span color=\"#e36f00;\">p</span><span color=\"#e75f00;\">l</span><span color=\"#eb4f00;\">e</span><span color=\"#ef3f00;\">t</span><span color=\"#f32f00;\">e</span><span color=\"#f71f00;\">d</span><span color=\"#fb0f00;\">!</span><br/>%s</font>", current_quest_data.display_name);
		
			PrintToChatAll("%s \x02%N\x01 completed the '\x04%s\x01' Quest!", PREFIX, client, current_quest_data.display_name);
		}
		
		g_QuestsProgress[client].SetArray(client_quest_index, client_quest_progress);
	}
}

/***************************
			Shop
****************************/

public void Shop_Started()
{
	Shop_AddToFunctionsMenu(OnQuestsShopDisplay, OnQuestsShopSelect);
}

public void OnQuestsShopDisplay(int client, char[] buffer, int maxlength)
{
	FormatEx(buffer, maxlength, "Quests");
}

public bool OnQuestsShopSelect(int client)
{
	return Command_Quests(client, 0) == Plugin_Handled;
}

void RemoveFunctionFromShop()
{
	Shop_RemoveFromFunctionsMenu(OnQuestsShopDisplay, OnQuestsShopSelect);
}

/****************************
			Menus
*****************************/
void Menu_MainQuestsMenu(int client)
{
	if (!g_QuestsProgress[client])
	{
		PrintToChat(client, "%s Your quests didn't load yet, please try again later!", PREFIX);
		return;
	}

	g_QuestsProgress[client].SortCustom(SortByCompletionPrecentage);
	
	Menu menu = new Menu(MenuHandler_MainQuestsMenu, MenuAction_Select);
	
	menu.SetTitle("Daily Quests:\n ");
	
	QuestProgress current_quest_progress;
	char menu_display_buffer[64];
	for (int current_quest = 0; current_quest < g_QuestsProgress[client].Length; current_quest++)
	{
		g_QuestsProgress[client].GetArray(current_quest, current_quest_progress);
		
		// Get Quest Name
		g_Quests.GetString(current_quest_progress.index, menu_display_buffer, sizeof(menu_display_buffer));
		
		int times_to_achieve = g_Quests.Get(current_quest_progress.index, Quest::times_to_achieve);
		
		// Format everything together.
		if (times_to_achieve == current_quest_progress.progress)
		{
			Format(menu_display_buffer, sizeof(menu_display_buffer), "[Completed] %s", menu_display_buffer);
		}
		else
		{
			Format(menu_display_buffer, sizeof(menu_display_buffer), "[%d/%d] %s", current_quest_progress.progress, times_to_achieve, menu_display_buffer);
		}
		
		// Add item to menu
		menu.AddItem("", menu_display_buffer);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

int MenuHandler_MainQuestsMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			Menu_QuestDitailsMenu(param1, param2);
		}
		
		case MenuAction_End:
		{
			delete menu;
		}
	}
}

void Menu_QuestDitailsMenu(int client, int quest_index)
{
	// Client progress
	QuestProgress client_progress;
	g_QuestsProgress[client].GetArray(quest_index, client_progress);
	
	// Quest
	Quest quest;
	g_Quests.GetArray(client_progress.index, quest);
	
	int progress_percent = ((client_progress.progress * 100) / quest.times_to_achieve);
	
	Panel panel = new Panel();
	char menu_item_buffer[64];
	
	panel.SetTitle("Quest Info:\n ");
	
	FormatEx(menu_item_buffer, sizeof(menu_item_buffer), "Name: %s\n ", quest.display_name);
	panel.DrawText(menu_item_buffer);
	
	//FormatEx(menu_item_buffer, sizeof(menu_item_buffer), "Progress: [%d/%d]", quest.display_name);
	FormatEx(menu_item_buffer, sizeof(menu_item_buffer), "Progress: [%d/%d]", client_progress.progress, quest.times_to_achieve);
	panel.DrawText(menu_item_buffer);
	
	FormatEx(menu_item_buffer, sizeof(menu_item_buffer), "%s [%%%d]\n ", GetProgressBar(progress_percent / 10), progress_percent);
	panel.DrawText(menu_item_buffer);
	
	FormatEx(menu_item_buffer, sizeof(menu_item_buffer), "Rewards:");
	panel.DrawText(menu_item_buffer);
	
	if (quest.reward_xp)
	{
		FormatEx(menu_item_buffer, sizeof(menu_item_buffer), " • %d XP", quest.reward_xp);
		panel.DrawText(menu_item_buffer);
	}
	
	if (quest.reward_credits)
	{
		FormatEx(menu_item_buffer, sizeof(menu_item_buffer), " • %d Credits", quest.reward_credits);
		panel.DrawText(menu_item_buffer);
	}
	
	panel.DrawText(" ");
	
	panel.DrawItem("Go Back");
	
	panel.Send(client, PanelHandler_QuestDitailsMenu, MENU_TIME_FOREVER);
	
	delete panel;
}

int PanelHandler_QuestDitailsMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		Menu_MainQuestsMenu(param1);
	}
}

/*****************************
			Timers
******************************/
Action ReloadQuests(Handle timer)
{
	// Delete all quests from database
	g_Database.Query(Database_OnTableTurncated, "DELETE FROM `quests_progress`"); // "TRUNCATE TABLE `quests_progress`" SQLite not supported
	
	// Make sure we don't leak handles or leave events hooked.
	for (int current_quest = 0; current_quest < g_Quests.Length; current_quest++)
	{
		// Get Quest
		Quest current_quest_data;
		g_Quests.GetArray(current_quest, current_quest_data, sizeof(Quest));
		
		// Delete conditions
		delete current_quest_data.conditions;
		
		// Erase from quest so it wont show up in the 'FindSearch' lookup.
		g_Quests.Erase(current_quest);
		
		// Check if there are more quests using the same event, if there are, don't unhook yet.
		if (FindQuestByEvent(current_quest_data.event_name) == -1)
		{
			UnhookEvent(current_quest_data.event_name, OnQuestEvent);
		}
	}
	
	// Delete quests.
	delete g_Quests;
	
	// Load quests again.
	LoadQuests();
}

/*******************************
			Database
********************************/
void Database_OnConnection(Database db, const char[] error, any data)
{
	if (!(g_Database = db) || error[0])
	{
		SetFailState("Database connection failed, Error: '%s'", error);
	}
	
	// Create the quest progress table if it doesn't already exist.
	g_Database.Query(Database_OnTableCreated, "CREATE TABLE IF NOT EXISTS `quests_progress` (`accountid` int unsigned NOT NULL, `quest` varchar(128) NOT NULL, `progress` int NOT NULL DEFAULT 0, PRIMARY KEY (`accountid`, `quest`))", true);
}

void Database_OnTableCreated(Database db, DBResultSet results, const char[] error, any data)
{
	if (!db || !results || error[0])
	{
		SetFailState("[Database_OnTableCreated] Couldn't Create nor verify plugin table, Error: %s", error);
	}
	
	// Late load:
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientAuthorized(current_client) && !IsFakeClient(current_client))
		{
			LoadPlayerQuests(current_client);
		}
	}
}

void Database_OnTableTurncated(Database db, DBResultSet results, const char[] error, any stop_plugin_on_fail)
{
	// This will just give random quests, without querying anything.
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientAuthorized(current_client))
		{
			ProcessPlayerQuests(current_client);
		}
	}
}

void Database_OnClientDataLoaded(Database db, DBResultSet results, const char[] error, any userid)
{
	if (!db || !results || error[0])
	{
		LogError("[Database_OnClientDataLoaded] Failed to load client data from database, Error: %s", error);
		return;
	}
	
	int client = GetClientOfUserId(userid);
	
	// Process the results from the result set we got back only if the player is still connected.
	if (client)
	{
		ProcessPlayerQuests(client, results);
	}
}

void Database_FakeFastQuery(Database db, DBResultSet results, const char[] error, any data)
{
	if (!db || !results || error[0])
	{
		LogError("[Database_FakeFastQuery] Query failed, Error: %s", error);
	}
}

/*******************************
			Commands
********************************/
public Action Command_Quests(int client, int argc)
{
	Menu_MainQuestsMenu(client);
	return Plugin_Handled;
}

public Action Command_PrintQuests(int argc)
{
	for (int current_quest = 0; current_quest < g_Quests.Length; current_quest++)
	{
		Quest current_quest_data;
		g_Quests.GetArray(current_quest, current_quest_data, sizeof(Quest));
		PrintToServer("[%s]\nEvent: %s->%s\nTimes to achieve: %d\nRewards:\n\tXP: %d\n\tCredits: %d\nConditions:", 
			current_quest_data.display_name, 
			current_quest_data.event_name, 
			current_quest_data.userid_field, 
			current_quest_data.times_to_achieve, 
			current_quest_data.reward_xp, 
			current_quest_data.reward_credits);
		for (int current_condition = 0; current_condition < current_quest_data.conditions.Length; current_condition++)
		{
			QuestCondition current_condition_data;
			current_quest_data.conditions.GetArray(current_condition, current_condition_data, sizeof(QuestCondition));
			PrintToServer("\t%s == %s", current_condition_data.field, current_condition_data.value);
		}
	}
}
/*public Action Command_PrintClientQuests(int client, int argc)
{
	Quest current_quest_data;
	QuestProgress current_quest_progress;
	for (int current_quest = 0; current_quest < g_QuestsProgress[client].Length; current_quest++)
	{
		g_QuestsProgress[client].GetArray(current_quest, current_quest_progress);
		g_Quests.GetArray(current_quest_progress.index, current_quest_data);
		
		PrintToChat(client, "[%d] %s", current_quest, current_quest_data.display_name);
		PrintToChat(client, "Quest index: %d", current_quest_progress.index);
		PrintToChat(client, "Quest Progress: %d/%d", current_quest_progress.progress, current_quest_data.times_to_achieve);
	}
}*/
/**************************************
			Other Functions
***************************************/
void LoadQuests()
{
	g_Quests = new ArrayList(sizeof(Quest));
	
	// Load KeyValues Config
	KeyValues kv = CreateKeyValues("Quests");
	
	// Find the Config
	char file_path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, file_path, sizeof(file_path), "configs/quests.cfg");
	
	// Open file and go directly to the settings, if something doesn't work don't continue.
	if (!kv.ImportFromFile(file_path))
	{
		SetFailState("Couldn't load plugin config.");
	}
	
	g_DailyQuestAmount = kv.GetNum("daily_quest_amount", 1);
	
	kv.GetString("quest_complete_sound_path", g_QuestCompleteSound, sizeof(g_QuestCompleteSound));
	
	if (!kv.GotoFirstSubKey())
	{
		SetFailState("Found your config but there are no quests here!");
	}
	
	// Quests
	do
	{
		Quest new_quest;
		
		// display_name
		kv.GetSectionName(new_quest.display_name, sizeof(Quest::display_name));
		
		// event_name
		kv.GetString("event", new_quest.event_name, sizeof(Quest::event_name));
		
		// Hook the event only if it didn't get hooked already.
		if (FindQuestByEvent(new_quest.event_name) == -1)
		{
			new_quest.HookQuestEvent(OnQuestEvent);
		}
		
		// userid_field
		kv.GetString("userid_field", new_quest.userid_field, sizeof(Quest::userid_field));
		
		// times_to_achieve
		new_quest.times_to_achieve = kv.GetNum("times_to_achieve", 1);
		
		// conditions
		if (kv.JumpToKey("conditions"))
		{
			if (kv.GotoFirstSubKey(false))
			{
				// Initialize the conditions Array-List.
				new_quest.Init();
				
				// Parse conditions.
				do
				{
					QuestCondition new_condition;
					
					// Get condition field.
					kv.GetSectionName(new_condition.field, sizeof(QuestCondition::field));
					
					// Get condition value it must match.
					kv.GetString(NULL_STRING, new_condition.value, sizeof(QuestCondition::value));
					
					// Add condition to the conditions Array-List.
					new_quest.conditions.PushArray(new_condition);
					
				} while (kv.GotoNextKey(false));
				
				kv.GoBack();
			}
			
			kv.GoBack();
		}
		
		// Parse the rewards
		if (kv.JumpToKey("rewards"))
		{
			// Get XP reward.
			new_quest.reward_xp = kv.GetNum("xp");
			
			// Get Credits reward.
			new_quest.reward_credits = kv.GetNum("credits");
			
			// Go back to main node
			kv.GoBack();
		}
		
		// Push this quest.
		g_Quests.PushArray(new_quest);
	} while (kv.GotoNextKey());
	
	// Don't leak handles.
	kv.Close();
}

void LoadPlayerQuests(int client)
{
	// Load quests from database
	char query[128];
	Format(query, sizeof(query), "SELECT `quest`, `progress` FROM `quests_progress` WHERE `accountid` = %u", GetSteamAccountID(client));
	
	#if defined DEBUG
	LogMessage("[LoadPlayerQuests] Query: %s", query);
	#endif
	
	g_Database.Query(Database_OnClientDataLoaded, query, GetClientUserId(client));
}

void ProcessPlayerQuests(int client, DBResultSet query_results = null)
{
	// Just incase there is something there?
	delete g_QuestsProgress[client];
	
	// Init client quests progress ArrayList.
	g_QuestsProgress[client] = new ArrayList(sizeof(QuestProgress));
	
	char quest_name[64];
	// Add quests to the player, from the database and random ones if needed.
	while (g_QuestsProgress[client].Length < g_DailyQuestAmount - 1)
	{
		QuestProgress new_quest;
		
		#if defined DEBUG
		LogMessage("[ProcessPlayerQuests] g_QuestsProgress[client].Length = %d", g_QuestsProgress[client].Length);
		#endif
		
		// Add quests the client already started
		if (query_results && query_results.FetchRow())
		{
			#if defined DEBUG
			LogMessage("[ProcessPlayerQuests] Row fetched");
			#endif
			
			// Get quest name from fetched row.
			query_results.FetchString(0, quest_name, sizeof(quest_name));
			
			#if defined DEBUG
			LogMessage("[ProcessPlayerQuests] quest_name: %s", quest_name);
			#endif
			
			// Get the index of the quest
			if ((new_quest.index = FindQuestByName(quest_name)) == -1)
			{
				#if defined DEBUG
				LogMessage("[ProcessPlayerQuests] '%s' not found in g_Quests", quest_name);
				#endif
				
				continue;
			}
			
			new_quest.progress = query_results.FetchInt(1);
			
			#if defined DEBUG
			LogMessage("[ProcessPlayerQuests] '%s' found in g_Quests (index: %d, progress: %d)", quest_name, new_quest.index, new_quest.progress);
			#endif
		}
		// if the client is missing some quests and there are more quests in the global variable, add random ones.
		else if (g_QuestsProgress[client].Length < g_Quests.Length)
		{
			#if defined DEBUG
			LogMessage("[ProcessPlayerQuests] Giving random quest.");
			#endif
			// Get random quest
			do
			{
				new_quest.index = GetRandomInt(0, g_Quests.Length - 1);
			} while (g_QuestsProgress[client].FindValue(new_quest.index, QuestProgress::index) != -1);
		}
		// No more quests to give.
		else
		{
			LogMessage("There aren't enough quests to give, to reach the daily amount. (Quests avilable: %d, Daily Quest Amount: %d)", g_Quests.Length, g_DailyQuestAmount);
			break;
		}
		
		// Add quest to player.
		g_QuestsProgress[client].PushArray(new_quest);
		
		#if defined DEBUG
		LogMessage("[ProcessPlayerQuests] Gave quest: [Index: %d, progress: %d]", new_quest.index, new_quest.progress);
		#endif
	}
}

char GetProgressBar(int progress_percent)
{
	char progress_bar[32];
	
	for (int current_progress = 0; current_progress < 10; current_progress++)
	{
		StrCat(progress_bar, sizeof(progress_bar), current_progress < progress_percent ? PROGRESS_CHAR_PROGRESS : PROGRESS_CHAR_REMAINING);
	}
	
	return progress_bar;
}

int SortByCompletionPrecentage(int index1, int index2, Handle array, Handle hndl)
{
	ArrayList arSort = view_as<ArrayList>(array);
	
	QuestProgress item1; arSort.GetArray(index1, item1);
	QuestProgress item2; arSort.GetArray(index2, item2);
	
	float completion_percentage1 = float(item1.progress) / float(g_Quests.Get(item1.index, Quest::times_to_achieve));
	float completion_percentage2 = float(item2.progress) / float(g_Quests.Get(item2.index, Quest::times_to_achieve));
	
	float substruction = completion_percentage1 - completion_percentage2;
	
	if (substruction > 0.0)
	{
		return (completion_percentage1 == 1.0) ? 1 : -1;
	}
	
	if (substruction < 0.0)
	{
		return (completion_percentage2 == 1.0) ? -1 : 1;
	}
	
	return 0;
}

bool IsSpecialFieldOrValue(char[] value, int len)
{
	int last_chr = strlen(value) - 1;
	if (value[0] == '<' && value[last_chr] == '>')
	{
		// Remove first and last characters
		value[last_chr] = '\0';
		strcopy(value, len, value[1]);
		
		return true;
	}
	
	return false;
}

int FindQuestByName(const char[] quest_name)
{
	Quest current_quest_data;
	for (int current_quest = 0; current_quest < g_Quests.Length; current_quest++)
	{
		g_Quests.GetArray(current_quest, current_quest_data);
		if (StrEqual(current_quest_data.display_name, quest_name))
		{
			return current_quest;
		}
	}
	
	return -1;
}

int FindQuestByEvent(const char[] event_name)
{
	Quest current_quest_data;
	for (int current_quest = 0; current_quest < g_Quests.Length; current_quest++)
	{
		g_Quests.GetArray(current_quest, current_quest_data);
		if (StrEqual(current_quest_data.event_name, event_name))
		{
			return current_quest;
		}
	}
	
	return -1;
}

void ShowPanel2(int client, int duration, const char[] format, any ...)
{
	char formatted_message[1024];
	VFormat(formatted_message, sizeof(formatted_message), format, 4);
	
	Event show_survival_respawn_status = CreateEvent("show_survival_respawn_status");
	if (show_survival_respawn_status != null)
	{
		show_survival_respawn_status.SetString("loc_token", formatted_message);
		show_survival_respawn_status.SetInt("duration", duration);
		show_survival_respawn_status.SetInt("userid", -1);
		
		show_survival_respawn_status.FireToClient(client);
	}

	delete show_survival_respawn_status;
}