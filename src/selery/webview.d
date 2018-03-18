/*
 * Copyright (c) 2017-2018 sel-project
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 */
module selery.webview;

import std.bitmanip : nativeToLittleEndian;
import std.concurrency : spawn;
import std.json : JSONValue;
import std.string : indexOf, strip;

import selery.about;
import selery.hub.plugin;
import selery.util.util : seconds;

import lighttp;

struct Address {

	string ip;
	ushort port;

}

class Main : HubPlugin {

	@start onStart() {
		spawn(&startWebView, server, plugin, [Address("0.0.0.0", 80)].idup);
	}

}

void startWebView(shared HubServer server, shared Plugin plugin, immutable(Address)[] addresses) {

	auto http = new Server(new WebViewRouter(server, cast()plugin));
	foreach(address ; addresses) {
		http.host(address.ip, address.port);
	}
	
	while(true) http.eventLoop.loop();

}

class WebViewRouter : Router {

	private shared HubServer server;
	private Plugin plugin;
	
	// never reloaded
	@Get("/background.png") Resource background;
	
	// may be reloaded
	@Get("/") Resource index;
	@Get("/info.json") Resource info;
	@Get("/icon.png") Resource icon;
	
	Resource status;
	uint lastStatusUpdate;
	
	this(shared HubServer server, Plugin plugin) {
		this.server = server;
		this.plugin = plugin;
		this.background = new Resource("image/png", server.files.readPluginAsset(plugin, "res/background.png"));
		this.index = new Resource("text/html");
		this.info = new Resource("application/json; charset=utf-8");
		this.icon = new Resource("image/png");
		this.status = new Resource("application/octet-stream");
		this.reload();
	}
	
	private void reload() {
	
		string readAsset(string file) {
			return cast(string)this.server.files.readPluginAsset(this.plugin, file);
		}
	
		// index
		string[string] repl = [
			"title": this.server.config.hub.displayName,
			"software": Software.display,
			"style": readAsset("style.css"),
			"script": readAsset("script.js"),
		];
		ptrdiff_t i = 0, start;
		string index = readAsset("index.html");
		while((start = index[i..$].indexOf("{{")) != -1) {
			start += i;
			immutable end = index[start..$].indexOf("}}") + start;
			string value = repl[index[start+2..end].strip];
			index = index[0..start] ~ value ~ index[end+2..$];
			i = start + value.length;
		}
		this.index.data = index;
		
		// info
		this.reloadInfo();
		
		// icon
		if(this.server.icon.data.length) {
			this.icon.data = this.server.icon.data;
		} else {
			this.icon.data = this.server.files.readPluginAsset(this.plugin, "res/icon.png");
		}
	
	}
	
	private void reloadInfo() {
		const config = this.server.config.hub;
		JSONValue[string] json, software, protocols;
		with(Software) {
			software["name"] = name;
			software["display"] = display;
			software["codename"] = ["name": codename, "emoji": codenameEmoji];
			software["version"] = JSONValue(["major": JSONValue(major), "minor": JSONValue(minor), "patch": JSONValue(patch)]);
			if(config.bedrock) protocols["bedrock"] = JSONValue(config.bedrock.protocols);
			if(config.java) protocols["java"] = JSONValue(config.java.protocols);
			json["software"] = JSONValue(software);
			json["protocols"] = JSONValue(protocols);
		}
		this.info.data = JSONValue(json).toString();
	}
	
	private void reloadStatus() {
		ubyte[] status = nativeToLittleEndian(this.server.onlinePlayers) ~ nativeToLittleEndian(this.server.maxPlayers);
		{
			//TODO add an option to disable showing players
			immutable show_skin = (this.server.onlinePlayers <= 32);
			foreach(player ; this.server.players) {
				immutable skin = (show_skin && player.skin !is null) << 15;
				status ~= nativeToLittleEndian(player.id);
				status ~= nativeToLittleEndian(to!ushort(player.displayName.length | skin));
				status ~= cast(ubyte[])player.displayName;
				if(skin) status ~= player.skin.face;
			}
		}
		this.status.data = status;
		this.lastStatusUpdate = seconds;
	}
	
	@Get("/status") _status(Request req, Response res) {
		if(seconds - this.lastStatusUpdate > 10) this.reloadStatus();
		this.status.apply(req, res);
	}

}

/+

void startWebView(shared HubServer server, Address address) {

	shared WebResource icon;
	shared string info;
	shared WebResource status;

	shared string iconRedirect = null;

	shared ulong lastStatusUpdate;
	
	shared size_t sessionsCount;
	
	
	public shared void reloadWebResources() {
		
		const config = this.server.config;
		
		// icon.png
		this.icon = WebResource.init;
		this.iconRedirect = null;
		with(this.server.icon) {
			if(url.length) {
				this.iconRedirect = url;
			} else if(data.length) {
				// must be valid if not empty
				this.icon.uncompressed = cast(string)data;
				this.icon.compress();
			}
		}
		
		// status.json
		this.reloadWebStatus();
		
	}
	
	private shared Response handleConnection(Socket socket, Request request) {
		if(!request.valid || request.path.length == 0 || "host" !in request.headers) return Response.error(StatusCodes.badRequest);
		if(request.method != "GET") return Response.error(StatusCodes.methodNotAllowed, ["Allow": "GET"]);
		switch(decode(request.path[1..$])) {
			case "":
				const config = this.server.config.hub;
				immutable host = request.headers["host"];
				return Response(StatusCodes.ok, ["Content-Type": "text/html"], compileDietFile!("view.dt", config, host));
			case "info.json":
				return Response(StatusCodes.ok, ["Content-Type": "application/json; charset=utf-8"], this.info);
			case "social.json":
				return Response(StatusCodes.ok, ["Content-Type": "application/json; charset=utf-8"], *this.socialJson);
			case "status":
				auto time = seconds;
				if(time - this.lastStatusUpdate > 10) this.reloadWebStatus();
				auto response = Response(StatusCodes.ok, ["Content-Type": "application/octet-stream"], this.status.uncompressed);
				if(this.status.isCompressed) {
					response = this.returnWebResource(this.status, request, response);
				}
				return response;
			case "icon.png":
				if(this.iconRedirect !is null) {
					return Response.redirect(StatusCodes.temporaryRedirect, this.iconRedirect);
				} else if(this.icon.compressed !is null) {
					auto response = Response(StatusCodes.ok, ["Content-Type": "image/png"]);
					return this.returnWebResource(this.icon, request, response);
				} else {
					return Response.redirect("//i.imgur.com/uxvZbau.png");
				}
			case "icon":
				return Response.redirect("/icon.png");
			case Software.codenameEmoji:
				return Response(Status(418, "I'm a " ~ Software.codename.toLower), ["Content-Type": "text/html"], "<head><meta charset='UTF-8'/><style>span{font-size:128px}</style><script>function a(){document.body.innerHTML+='<span>" ~ Software.codenameEmoji ~ "</span>';setTimeout(a,Math.round(Math.random()*2500));}window.onload=a;</script></head>");
			case "software":
				return Response.redirect(Software.website);
			case "website":
				if(this.website.length) {
					return Response.redirect("//" ~ this.website);
				} else {
					return Response.error(StatusCodes.notFound);
				}
			default:
				if(request.path.startsWith("/player_") && request.path.endsWith(".json")) {
					try {
						auto player = this.server.playerFromId(to!uint(request.path[8..$-5]));
						if(player !is null) {
							JSONValue[string] json;
							json["name"] = player.username;
							json["display"] = player.displayName;
							json["version"] = player.game;
							if(player.skin !is null) json["skin"] = player.skin.faceBase64;
							if(player.world !is null) json["world"] = ["name": JSONValue(player.world.name), "dimension": JSONValue(player.dimension)];
							return Response(StatusCodes.ok, ["Content-Type": "application/json; charset=utf-8"], JSONValue(json).toString());
						}
					} catch(Exception) {}
					return Response(StatusCodes.notFound, ["Content-Type": "application/json; charset=utf-8"], `{"error":"player not found"}`);
				}
				return Response.error(StatusCodes.notFound);
		}
	}
	
}

+/