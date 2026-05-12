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
	# Crawler arrival_radius is tighter than the GroundMovement default
	# (6.0u, sized for the outer ring of a 20-unit crowd). Crawlers are
	# always solo, so 6u meant short click-orders inside the radius
	# triggered immediate ARRIVED → SEEK suppressed → crawler didn't move.
	# 3.0u is just over the chassis half-width (chassis is 3.8×5.2u, so
	# centre→edge ~2.6u) and gives short clicks room to actually drive.
	# Overshoot/orbit risk is minor at the slow crawler max_speed.
	arrival_radius = 3.0


## PF-B — crawlers always use the large agent class regardless of what's
## in their .tres file. Their chassis radius is defined by the movement
## component (this file), not by the stat resource, so authors can't
## accidentally configure a crawler with the wrong cost-grid profile.
func _agent_class_for_self() -> int:
	return 2  # AGENT_CLASS_LARGE
