#include < amxmodx >
#include < amxmisc >
#include < time >
#include < sqlx >


#define MOTD_CHECK          "http://localhost:8080/cs/CookieCheck/index.php"
#define MAX_COOKIE_SIZE     35
#define DEFAULT_TIME        60  // ban time default in minutes
#define ADMIN_FLAG          ADMIN_BAN


#define TASK_GETBID         12611


new const host[] = "127.0.0.1";
new const user[] = "root";
new const pass[] = "";
new const db[]   = "mysql_dust";

new const bannedCookies[] = "db_bancookies";
new const checkedCookies[] = "db_checkcookies";
new const bansTable[] = "acp_bans_history";                          // change this to the bans table name

new Handle:hTuple;

enum _:PlayerData
{   
    TIME = 0,
    ID,
    NAME[ 32 ],
    COOKIE[ MAX_COOKIE_SIZE ],
    IP[ MAX_IP_LENGTH ]
}

new pcvar_complainurl;

new p_server;

public plugin_init()
{
    register_plugin( "Cookie Bans for AMXBans", "2.1.1", "DusT" );
    // admin commands
    register_concmd( "amx_ban", "CmdBan" );
    register_concmd( "cookie_remove", "CookieRemove", ADMIN_FLAG, "< nick > - removes nick from cookie bans." );
    register_concmd( "cookie_ban", "CmdCookieBan", ADMIN_FLAG, "< nick | steamid | #id > [ time ] - Bans with cookies." );

    register_message( get_user_msgid("MOTD"), "MessageMotd" )
    
    p_server = register_cvar( "cookie_server", "1" );
    register_cvar( "amxbans_complain_url", "dust-pro.com" );
    pcvar_complainurl = get_cvar_pointer( "amxbans_complain_url" );
    hTuple = SQL_MakeDbTuple( host, user, pass, db );
    register_dictionary( "amxbans.txt" );
    register_dictionary( "time.txt" );
}

public MessageMotd( msgId, msgDest, msgEnt)
{
    set_msg_arg_int( 1, ARG_BYTE, 1 );
    set_msg_arg_string( 2, fmt( "%s?uid=%d&srv=%d", MOTD_CHECK, get_user_userid( msgEnt ), get_pcvar_num( p_server ) ) );
    
    
    return PLUGIN_CONTINUE;
}
public plugin_cfg()
{
    set_task( 0.1, "SQL_Init" );
}

public SQL_Init()
{
    new szQuery[ 512 ];
    
    formatex( szQuery, charsmax( szQuery ), "CREATE TABLE IF NOT EXISTS `%s` ( `id` INT NOT NULL AUTO_INCREMENT, `first_nick` VARCHAR(31) NOT NULL, `banid` INT NOT NULL, `ban_length` INT NOT NULL, `cookie` VARCHAR( %d ) NOT NULL, PRIMARY KEY ( id ) );", bannedCookies, MAX_COOKIE_SIZE );
    SQL_ThreadQuery( hTuple, "IgnoreHandle", szQuery );

    formatex( szQuery, charsmax( szQuery ), "CREATE TABLE IF NOT EXISTS `%s` ( `id` INT NOT NULL AUTO_INCREMENT, `uid` INT NOT NULL UNIQUE, `cookie` VARCHAR( %d ) NOT NULL UNIQUE, `server` INT NOT NULL, PRIMARY KEY ( id ) );", checkedCookies, MAX_COOKIE_SIZE );
    SQL_ThreadQuery( hTuple, "IgnoreHandle", szQuery );

    formatex( szQuery, charsmax( szQuery ), "DELETE FROM `%s` WHERE `ban_length` < UNIX_TIMESTAMP();", bannedCookies );
    SQL_ThreadQuery( hTuple, "IgnoreHandle", szQuery );
}

public IgnoreHandle( failState, Handle:query, error[], errNum )
{
    if( errNum )
    {
        set_fail_state( error );
    }
    SQL_FreeHandle( query );
}

public client_putinserver( id )
{
    set_task( 3.5, "SQL_CheckCookie", id );
}

public client_disconnected( id )
{
    if( task_exists( id ) )
        remove_task( id );
}

public plugin_end()
{
    SQL_ThreadQuery( hTuple, "IgnoreHandle", fmt( "DELETE FROM `%s`", checkedCookies ) );
}

public CmdBan( id )
{
    if( !( get_user_flags( id ) & ADMIN_FLAG ) )
        return PLUGIN_CONTINUE;
    
    if( read_argc() < 4 )
        return PLUGIN_CONTINUE;
    
    new argv[ 32 ], time;
    read_argv( 2, argv, charsmax( argv ) );
    time = read_argv_int( 1 ); 
    new pid = cmd_target( id, argv, CMDTARGET_ALLOW_SELF );
    if( !pid )
        return PLUGIN_CONTINUE;
    new data[ PlayerData ];
    get_user_name( pid, data[ NAME ], charsmax( data[ NAME ] ) );
    data[ ID ] = pid;
    data[ TIME ] = get_systime() + ( ( time == 0 )? 31536000 * 2 : time * 60 ); 
    get_user_ip( id, data[ IP ], charsmax( data[ IP ] ), 1 );
    // get cookie from checkedCookies table
    SQL_ThreadQuery( hTuple, "SQL_GetCookie", fmt( "SELECT `cookie` FROM `%s` WHERE `uid`=%d AND `server`=%d;", checkedCookies, get_user_userid( pid ), get_pcvar_num( p_server ) ), data, sizeof data );
    
    return PLUGIN_CONTINUE;
}
// retrieve cookie and save in data[ COOKIE ]
public SQL_GetCookie( failState, Handle:query, error[], errNum, data[], dataSize )
{
    if( !SQL_NumResults( query ) )
    {
        server_print( "Couldn't find cookie" );
        return;
    }
        
    SQL_ReadResult( query, 0, data[ COOKIE ], charsmax( data[ COOKIE ] ) );

    if( data[ IP ][ 0 ] )
        set_task( 5.0, "SQL_GetBid", dataSize + TASK_GETBID, data, dataSize );
    else
        BanCookie( data[ NAME ], data[ COOKIE ], 0, data[ TIME ] );
}
public SQL_GetBid( data[], taskId )
{
    taskId -= TASK_GETBID;

    //search by IP rather than nick is better. 
    SQL_ThreadQuery( hTuple, "SQL_GetBidHandler", fmt( "SELECT `bid` FROM `%s` WHERE `player_ip`='%s';", bansTable, data[ IP ] ), data, taskId );
}

public SQL_GetBidHandler( failState, Handle:query, error[], errNum, data[], dataSize )
{
    new bid = ( ( SQL_NumResults( query ) )? SQL_ReadResult( query, 0 ):0 );
    BanCookie( data[ NAME ], data[ COOKIE ], bid, data[ TIME ] );
}

// save cookie and check if cookie is in the banned db
public SQL_CheckCookie( id )
{
    if( !is_user_connected( id ) )
        return;
    new data[ 2 ];
    data[ 0 ] = id;
    SQL_ThreadQuery( hTuple, "SQL_CheckCookieHandler", fmt( "SELECT * FROM `%s` WHERE `cookie` = ( SELECT `cookie` FROM `%s` WHERE `uid` = %d AND `server`=%d );", bannedCookies, checkedCookies, get_user_userid( id ), get_pcvar_num( p_server ) ), data, sizeof data );
}


public SQL_CheckCookieHandler( failState, Handle:query, error[], errNum, data[], dataSize )
{
    if( errNum )
    {
        set_fail_state( error );
    }
    new id = data[ 0 ];
    if( !is_user_connected( id ) )
        return;
    if( !SQL_NumResults( query ) )
        return;
    new bid = SQL_ReadResult( query, SQL_FieldNameToNum( query, "banid" ) );
    if( bid )
        SQL_ThreadQuery( hTuple, "SQL_FindBan", fmt( "SELECT bid,ban_created,ban_length,ban_reason,admin_nick,player_nick,player_id,player_ip,server_name FROM `%s` WHERE `bid` = %d", bansTable, bid ), data, dataSize );
    else
    {
        new ban_length = SQL_ReadResult( query, SQL_FieldNameToNum( query, "ban_length" ) );
        if( ban_length > get_systime() )    // kick only if cookie's ban length is longer than current time.
            server_cmd( "kick #%d You are banned!", get_user_userid( id ) );
    }
}

public SQL_FindBan( failState, Handle:query, error[], errNum, data[], dataSize )
{
    new id = data[ 0 ];
    if( !is_user_connected( id ) )
        return;

    if( !SQL_NumResults( query ) )
        return;

    // mostly taken from amxbans plugin   
    new ban_reason[ 64 ], admin_nick[ 32 ];
    new player_nick[ 32 ], player_steamid[ 30 ], player_ip[ 20 ], server_name[ 64 ];

    new ban_created = SQL_ReadResult( query, 1 );
    new ban_length_int = SQL_ReadResult( query, 2 ) * 60;
    SQL_ReadResult( query, 3, ban_reason, charsmax( ban_reason ) );
    SQL_ReadResult( query, 4, admin_nick, charsmax( admin_nick ) );
    SQL_ReadResult( query, 5, player_nick, charsmax( player_nick ) );
    SQL_ReadResult( query, 6, player_steamid, charsmax( player_steamid ) );
    SQL_ReadResult( query, 7, player_ip, charsmax( player_ip ) );
    SQL_ReadResult( query, 8, server_name, charsmax( server_name ) );

    new curr_steamid[ 30 ], curr_ip[ 20 ];
    get_user_authid( id, curr_steamid, charsmax( curr_steamid ) );
    get_user_ip( id, curr_ip, charsmax( curr_ip ), 1 );

    // in case it has same IP or steamid as a ban, let amxbans ban him instead of cookie.
    if( equali( player_steamid, curr_steamid ) || equali( player_ip, curr_ip ) )    
        return;

    new current_time_int = get_systime();
    if( ban_length_int == 0 || ban_created == 0 || ban_length_int + ban_created > current_time_int )
    {
        client_cmd(id, "echo [AMXBans] ===============================================")
        new complain_url[256]
        get_pcvar_string(pcvar_complainurl ,complain_url,255)

        client_cmd(id, "echo [AMXBans] %L",id,"MSG_8", admin_nick)
        if (ban_length_int==0) {
            client_cmd(id, "echo [AMXBans] %L",id,"MSG_10")
        } else {
            new cTimeLength[128]
            new iSecondsLeft = (ban_created + ban_length_int - current_time_int)
            get_time_length(id, iSecondsLeft, timeunit_seconds, cTimeLength, 127)
            client_cmd(id, "echo [AMXBans] %L" ,id, "MSG_12", cTimeLength)
        }

        replace_all(complain_url,charsmax(complain_url),"http://","")

        client_cmd(id, "echo [AMXBans] %L", id, "MSG_13", player_nick)
        client_cmd(id, "echo [AMXBans] %L", id, "MSG_2", ban_reason)
        client_cmd(id, "echo [AMXBans] %L", id, "MSG_7", complain_url)
        client_cmd(id, "echo [AMXBans] %L", id, "MSG_4", player_steamid)
        client_cmd(id, "echo [AMXBans] %L", id, "MSG_5", player_ip)
        client_cmd(id, "echo [AMXBans] ===============================================")

        set_task(3.5, "delayed_kick", id );
    }

}

public delayed_kick( id )
{
    if( is_user_connected( id ) )
        server_cmd( "kick #%d You are BANNED. Check your console.", get_user_userid( id ) );
}
public CookieRemove( id, level, cid )
{
    if( !cmd_access( id, level, cid, 2 ) )
        return PLUGIN_HANDLED;
    new argv[ 32 ];
    read_argv( 1, argv, charsmax( argv ) );
    new nick[ 64 ];
    SQL_QuoteString( Empty_Handle, nick, charsmax( nick ), argv );
    SQL_ThreadQuery( hTuple, "IgnoreHandle", fmt( "DELETE FROM `%s` WHERE `first_nick` = '%s'", bannedCookies, nick ) );

    if( id )
        client_print( id, print_console, "Done" );
    else
        server_print( "Done" );
    return PLUGIN_HANDLED;
}
public CmdCookieBan( id, level, cid )
{
    if( !cmd_access( id, level, cid, 2 ) )
        return PLUGIN_HANDLED;
    new argv[ 32 ];
    read_argv( 1, argv, charsmax( argv ) );
    new data[ PlayerData ];
    data[ ID ] = cmd_target( id, argv, CMDTARGET_ALLOW_SELF );
    
    if( data[ ID ] )
    {
        data[ TIME ] = get_systime() + ( ( read_argc() < 3 )? DEFAULT_TIME*60:(read_argv_int( 2 ) == 0 )? 31536000 * 2:read_argv_int( 2 )*60 );
        get_user_name( data[ ID ], data[ NAME ], charsmax( data[ NAME ] ) );
        SQL_ThreadQuery( hTuple, "SQL_GetCookie", fmt( "SELECT `cookie` FROM `%s` WHERE `uid`=%d AND `server`=%d;", checkedCookies, get_user_userid( data[ ID ] ), get_pcvar_num( p_server ) ), data, sizeof data );
    }
    return PLUGIN_HANDLED;
}

BanCookie( name[], cookie[], bid = 0, time = DEFAULT_TIME )
{
    if( time == DEFAULT_TIME )
        time = ( time * 60 ) + get_systime();
    new nick[ 64 ];
    SQL_QuoteString( Empty_Handle, nick, charsmax( nick ), name );

    SQL_ThreadQuery( hTuple, "IgnoreHandle", fmt( "INSERT INTO `%s` VALUES( NULL, '%s', %d, %d, '%s'  );", bannedCookies, nick, bid, time, cookie ) );
    new id = find_player( "a", name )
    if( id )
        set_task( 3.5, "delayed_kick", id );
}
