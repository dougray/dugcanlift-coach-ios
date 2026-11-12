import SwiftUI
import LiftCore

/// What a street map is drawn from and under which licences, as LiftKit's
/// `NOTICE` states them (LiftMap links MapLibre Native as a binary, ships Noto
/// Sans glyphs, and draws OpenStreetMap data served by OpenFreeMap). The BSD-2
/// text is MapLibre Native 6.31.0's, word for word, because that licence asks
/// for it to travel with the binary.
struct MapCreditsView: View {
    static let streetData = "Street data © OpenStreetMap contributors, Open Database License (ODbL) 1.0 — openstreetmap.org/copyright. Vector tiles from OpenFreeMap — openfreemap.org."
    static let fonts = "Map labels use Noto Sans Regular, SIL Open Font License 1.1."
    static let mapLibre = "Maps are drawn with MapLibre Native, BSD 2-Clause License."

    /// MapLibre Native's license, as the release the kit links ships it.
    static let mapLibreLicense = """
    BSD 2-Clause License

    Copyright (c) 2021 MapLibre contributors

    Copyright (c) 2018-2021 MapTiler.com

    Copyright (c) 2014-2020 Mapbox

    Redistribution and use in source and binary forms, with or without \
    modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice, \
    this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above copyright notice, \
    this list of conditions and the following disclaimer in the documentation \
    and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE \
    ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE \
    LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR \
    CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF \
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS \
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) \
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE \
    POSSIBILITY OF SUCH DAMAGE.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.streetData)
            Text(Self.fonts)
            Text(Self.mapLibre)
        }
        .font(.footnote)
        .foregroundStyle(Theme.textSecondary)
        DisclosureGroup("MapLibre license") {
            Text(Self.mapLibreLicense)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(Theme.textPrimary)
    }
}
