import SwiftUI
import WidgetKit

@main
struct ComplexCommuteWidgets: WidgetBundle {
    var body: some Widget {
        NearbyDeparturesWidget()
        CommuteWidget()
        TripLiveActivity()
    }
}
