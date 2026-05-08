#include "flow_field_server.h"
#include <godot_cpp/core/class_db.hpp>

namespace drossfront {

void FlowFieldServer::_bind_methods() {
    using namespace godot;
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
}

FlowFieldServer::FlowFieldServer() {}
FlowFieldServer::~FlowFieldServer() {}

FieldId FlowFieldServer::build_field(godot::Vector3, int) { return INVALID_FIELD_ID; }
void FlowFieldServer::release_field(FieldId) {}
godot::Vector2 FlowFieldServer::sample(FieldId, godot::Vector3) { return godot::Vector2(); }
void FlowFieldServer::mark_obstacle(godot::AABB, bool) {}
void FlowFieldServer::mark_soft_cost(godot::AABB, int) {}

} // namespace drossfront
