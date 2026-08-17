import Foundation

/// Something the archive could lose, in the way archives actually lose things.
enum ArchiveLoss: Hashable {
    /// A device fails, is stolen, or is dropped. If it is this device, the staging
    /// area goes with it — photos that arrived but have not reached a drive yet
    /// live there and nowhere else.
    case device(UUID)
    /// The Google download files are deleted everywhere they exist. Not a
    /// device failing: the zips are the *same files* on each drive, so one
    /// decision takes every copy at once, which is the whole reason this is a
    /// failure mode of its own.
    case downloadsEverywhere
    /// The downloads are deleted from one device only — a tidy-up, not a
    /// disaster. Loses nothing while another device still holds them, and that
    /// is exactly why it is worth showing separately: it is the version of this
    /// somebody might actually do on purpose.
    case downloadsOn(UUID)
}

/// What the archive would be left with afterwards.
///
/// Built because "how many photos does this drive hold" is the wrong question
/// and the only one the app could answer. A device holding 21,389 of 21,401
/// photos sounds indispensable and is expendable; one holding 12 sounds
/// trivial and is a catastrophe if those 12 are nowhere else. Only counting
/// what would have *no surviving copy* separates them.
struct LossProjection: Equatable {
    /// Photos with no surviving copy at all.
    var lost: Int = 0
    /// Photos this loss would strip down to a single copy — counted only when
    /// they had more than one to begin with.
    ///
    /// The end state alone is the wrong measure. Every photo that was already
    /// alone stays alone through any failure, and folding those in blames a
    /// drive for redundancy it never had: on the fixture, deleting the
    /// downloads "reduced" six photos to one copy when it had actually cost
    /// exactly one its second home. What this number is for is the sentence
    /// *this failure would leave N photos on their last copy*, and that
    /// sentence is only true of photos the failure took something from.
    var reducedToOneCopy: Int = 0
    /// Photos that already had no copy before anything went wrong. Reported
    /// apart from `lost`, because blaming a device for photos it never held
    /// would overstate what losing it costs.
    var alreadyUnprotected: Int = 0
    /// Which groups take the damage, for a per-row answer.
    var lostByGroup: [UUID: Int] = [:]

    var isHarmless: Bool { lost == 0 }
}

extension LossProjection {

    /// Everything needed to answer the question, gathered once.
    ///
    /// Takes plain values rather than the store so the rules can be tested
    /// against an archive built to be awkward. The live archive is far too
    /// healthy to prove any of this: every photo on it is in two places, so
    /// every projection over it returns either nothing or everything, and a
    /// test that only ever sees those two answers has not tested the rule.
    struct Input {
        /// Photos only — a Live Photo is one photo though it is two files, and
        /// every sentence built from this says "photo".
        var photos: [Asset]
        var replicas: [TargetReplicaState]
        var groupOfAsset: [UUID: UUID]
        /// The registered target that *is* this device, if there is one.
        var hostTargetID: UUID?

        init(
            assets: [Asset],
            replicas: [TargetReplicaState],
            groupOfAsset: [UUID: UUID] = [:],
            hostTargetID: UUID? = nil
        ) {
            photos = assets.filter { $0.residency == .local && !$0.isLivePhotoMotion }
            self.replicas = replicas
            self.groupOfAsset = groupOfAsset
            self.hostTargetID = hostTargetID
        }
    }

    static func project(_ loss: ArchiveLoss, in input: Input) -> LossProjection {
        projectAll([loss], in: input)[loss] ?? LossProjection()
    }

    /// Every failure mode in one pass over the archive.
    ///
    /// Not a convenience: the chips that offer these are labelled with what
    /// each would cost, so all of them are wanted at once, on every redraw.
    /// Asking `project` four times means four walks of 21,401 photos, which is
    /// the shape of cost this screen has already been slow from once.
    ///
    /// It is also the reason there is one implementation rather than two — a
    /// bulk path that drifted from the single path would be a set of numbers
    /// that disagreed with each other on the same screen.
    static func projectAll(_ losses: [ArchiveLoss], in input: Input) -> [ArchiveLoss: LossProjection] {
        // Only a present replica is a copy. A pending one is a promise and a
        // damaged one no longer matches what was imported — counting either as
        // a survivor is how a screen tells somebody they are safe because a
        // copy exists that cannot be read back.
        var byAsset: [UUID: [TargetReplicaState]] = [:]
        for replica in input.replicas where replica.state == .present {
            byAsset[replica.assetID, default: []].append(replica)
        }

        var results: [ArchiveLoss: LossProjection] = [:]
        for loss in losses { results[loss] = LossProjection() }

        for photo in input.photos {
            let copies = byAsset[photo.id] ?? []
            // Staging is a copy — an unmanaged one, on this device. It is the only
            // thing standing between a just-imported photo and nothing, and it
            // has no replica row, so a model built from replicas alone reports
            // that losing this device costs zero and is wrong by exactly the
            // photos that most needed saying.
            let staged = photo.stagingRelativePath != nil

            if copies.isEmpty && !staged {
                for loss in losses { results[loss]?.alreadyUnprotected += 1 }
                continue
            }

            let before = copies.count + (staged ? 1 : 0)
            let group = input.groupOfAsset[photo.id]
            for loss in losses {
                let surviving = copies.reduce(0) { $0 + (survives($1, loss) ? 1 : 0) }
                    + (staged && !stagingIsLost(loss, host: input.hostTargetID) ? 1 : 0)
                if surviving == 0 {
                    results[loss]?.lost += 1
                    if let group { results[loss]?.lostByGroup[group, default: 0] += 1 }
                } else if surviving == 1 && before > 1 {
                    results[loss]?.reducedToOneCopy += 1
                }
            }
        }
        return results
    }

    private static func survives(_ replica: TargetReplicaState, _ loss: ArchiveLoss) -> Bool {
        switch loss {
        case .device(let id):
            return replica.targetID != id
        case .downloadsEverywhere:
            return !ReplicationService.isInsideADownload(replica.relativePath)
        case .downloadsOn(let id):
            guard replica.targetID == id else { return true }
            return !ReplicationService.isInsideADownload(replica.relativePath)
        }
    }

    /// Staging lives on this device, so it goes when this device does — and only
    /// then. Deleting downloads does not touch it, and neither does a drive
    /// failing.
    private static func stagingIsLost(_ loss: ArchiveLoss, host: UUID?) -> Bool {
        guard case .device(let id) = loss, let host else { return false }
        return id == host
    }
}
