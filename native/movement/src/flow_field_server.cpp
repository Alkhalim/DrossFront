#include "flow_field_server.h"
#include <godot_cpp/core/class_db.hpp>

namespace drossfront {

void FlowFieldServer::_bind_methods() {
#ifndef MOVEMENT_NATIVE_TESTS
    // Method binding requires the loaded-extension Godot runtime; in the
    // standalone doctest binary the binding machinery isn't initialized
    // and `bind_method` template instantiation fails to compile against
    // godot::_gde_UnexistingClass. The unit tests don't exercise the
    // GDScript dispatch path anyway — they call C++ methods directly.
    using namespace godot;
    ClassDB::bind_method(D_METHOD("configure_map", "grid_w", "grid_h",
                                  "cell_size", "origin_x", "origin_z"),
                         &FlowFieldServer::configure_map);
    ClassDB::bind_method(D_METHOD("set_agent_radius", "agent_class", "radius"),
                         &FlowFieldServer::set_agent_radius);
    ClassDB::bind_method(D_METHOD("build_field", "goal", "agent_class"),
                         &FlowFieldServer::build_field);
    ClassDB::bind_method(D_METHOD("release_field", "id"),
                         &FlowFieldServer::release_field);
    ClassDB::bind_method(D_METHOD("sample", "id", "world_pos"),
                         &FlowFieldServer::sample);
    ClassDB::bind_method(D_METHOD("mark_obstacle", "aabb", "blocked"),
                         &FlowFieldServer::mark_obstacle);
    ClassDB::bind_method(D_METHOD("mark_soft_cost", "aabb", "cost"),
                         &FlowFieldServer::mark_soft_cost);
    ClassDB::bind_method(D_METHOD("set_cell_y_at", "world_pos", "y"),
                         &FlowFieldServer::set_cell_y_at);
    ClassDB::bind_method(D_METHOD("get_cell_cost_at", "world_pos", "agent_class"),
                         &FlowFieldServer::get_cell_cost_at);
    ClassDB::bind_method(D_METHOD("get_cell_y_at", "world_pos"),
                         &FlowFieldServer::get_cell_y_at);
#endif
}

FlowFieldServer::FlowFieldServer() {}
FlowFieldServer::~FlowFieldServer() {}

} // namespace drossfront
