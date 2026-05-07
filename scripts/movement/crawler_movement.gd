class_name CrawlerMovement
extends GroundMovement
## Movement for the salvage_crawler — same as ground squads but with
## a much wider agent profile so paths route around obstacles big
## enough for the chassis. Plan A's "navmesh ends short of chassis"
## complaint is solved by querying paths with a larger radius.
##
## Plan B keeps this as a simple GroundMovement subclass. Plan C may
## introduce a per-profile baked nav region if the single navmesh
## starts producing wrong routes for the crawler.

func _ready() -> void:
	super._ready()
	# Override the default agent profile with crawler-sized radius.
	# 2.5u radius is enough to make path queries route around any
	# gap smaller than 5u — close to what the crawler chassis needs.
	agent_profile = AgentProfile.new(2.5, 0.5, 35.0, &"crawler")
	# Crawlers also have larger separation/avoid radii so other
	# agents push out of the way more decisively. avoid_min_distance
	# was 10u — wide enough that buildings near the destination kept
	# pushing the crawler around even after it should have settled.
	# 6u gives the chassis enough cushion to clear walls without
	# constantly fighting seek at the goal.
	separate_min_distance = 5.0
	avoid_min_distance = 6.0
	avoid_repel = 36.0
	# Default arrival_radius (3u) is smaller than the crawler's own
	# agent radius (2.5u + chassis) — physically the chassis can't get
	# within 3u of a target without overlapping. Wider arrival zone
	# (6u) gives more distance for decel to bring the chassis to rest
	# cleanly instead of overshooting and orbiting the goal.
	arrival_radius = 6.0
