// Request bodies. The relay validates shape and size only; what a body says is sealed.
import { BooleanField, CharField, ChoiceField, IntegerField, RegexField, Serializer } from '@ghuri/rest'
import { BASE64, LIMITS } from './limits'
import { ENTRY_KINDS } from './models'

const sealed = (maxLength: number) => new RegexField(BASE64, { maxLength, minLength: 1 })

export class EntryIn extends Serializer {
  clientId = new RegexField(/^[A-Za-z0-9_-]{8,40}$/)
  kind = new ChoiceField([...ENTRY_KINDS])
  body = sealed(LIMITS.entryBodyChars)
}

export class BriefIn extends Serializer {
  /** The rev this text was based on; 0 when creating the first one. */
  baseRev = new IntegerField({ minValue: 0 })
  body = sealed(LIMITS.briefBodyChars)
}

export class PresenceIn extends Serializer {
  body = sealed(LIMITS.presenceBodyChars)
}

export class MemberIn extends Serializer {
  name = new CharField({ maxLength: 60, minLength: 1 })
  isOwner = new BooleanField({ required: false, default: false })
}
