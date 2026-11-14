// Every route the relay serves. Pitwall is the only client; there is no admin, no
// browsable API and nothing at /.
import { path } from '@ghuri/core'
import {
  BriefHistoryView,
  BriefRevisionView,
  BriefView,
  EntriesView,
  FeedView,
  HealthView,
  MemberDetailView,
  MembersView,
  PresenceView,
} from './relay/views'

export const urlpatterns = [
  path('v1/health/', HealthView.asView(), { name: 'health' }),

  path('v1/p/<slug:project>/entries/', EntriesView.asView(), { name: 'entries' }),
  path('v1/p/<slug:project>/feed/', FeedView.asView(), { name: 'feed' }),
  path('v1/p/<slug:project>/brief/', BriefView.asView(), { name: 'brief' }),
  path('v1/p/<slug:project>/brief/history/', BriefHistoryView.asView(), { name: 'brief-history' }),
  path('v1/p/<slug:project>/brief/history/<int:rev>/', BriefRevisionView.asView(), { name: 'brief-revision' }),
  path('v1/p/<slug:project>/presence/', PresenceView.asView(), { name: 'presence' }),

  path('v1/members/', MembersView.asView(), { name: 'members' }),
  path('v1/members/<int:id>/', MemberDetailView.asView(), { name: 'member' }),
]
