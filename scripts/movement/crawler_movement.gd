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
	# agents (and the crawler itself) push out of the way more
	# decisively.
	separate_min_distance = 5.0
	avoid_min_distance = 10.0
	avoid_repel = 36.0
	# Default arrival_radius (2u) is smaller than the crawler's own
	# agent radius (2.5u) — physically the chassis can't get within
	# 2u of a target without overlapping it, so seek never reports
	# arrival and the unit circles its goal endlessly. Bump to 4u so
	# the chassis settles when its body is touching the target.
	arrival_radius = 4.0
