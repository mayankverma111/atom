_ = require 'underscore'
fsUtils = require 'fs-utils'
File = require 'file'
Point = require 'point'
Range = require 'range'
EventEmitter = require 'event-emitter'
UndoManager = require 'undo-manager'
BufferChangeOperation = require 'buffer-change-operation'
BufferMarker = require 'buffer-marker'

# Public: Represents the contents of a file.
#
# The `Buffer` is often associated with a {File}. However, this is not always
# the case, as a `Buffer` could be an unsaved chunk of text.
module.exports =
class Buffer
  @idCounter = 1
  registerDeserializer(this)
  stoppedChangingDelay: 300
  stoppedChangingTimeout: null
  undoManager: null
  cachedDiskContents: null
  cachedMemoryContents: null
  conflict: false
  lines: null
  lineEndings: null
  file: null
  validMarkers: null
  invalidMarkers: null
  refcount: 0

  # Internal:
  @deserialize: ({path, text}) ->
    project.bufferForPath(path, text)

  # Public: Creates a new buffer.
  #
  # path - A {String} representing the file path
  # initialText - A {String} setting the starting text
  constructor: (path, initialText) ->
    @id = @constructor.idCounter++
    @nextMarkerId = 1
    @validMarkers = {}
    @invalidMarkers = {}
    @lines = ['']
    @lineEndings = []

    if path
      @setPath(path)
      if initialText?
        @setText(initialText)
        @updateCachedDiskContents()
      else if fsUtils.exists(path)
        @reload()
      else
        @setText('')
    else
      @setText(initialText ? '')

    @undoManager = new UndoManager(this)

  # Internal:
  destroy: ->
    throw new Error("Destroying buffer twice with path '#{@getPath()}'") if @destroyed
    @file?.off()
    @destroyed = true
    project?.removeBuffer(this)

  retain: ->
    @refcount++
    this

  release: ->
    @refcount--
    @destroy() if @refcount <= 0
    this

  # Internal:
  serialize: ->
    deserializer: 'TextBuffer'
    path: @getPath()
    text: @getText() if @isModified()

  # Public: Identifies if the buffer belongs to multiple editors.
  #
  # For example, if the {Editor} was split.
  #
  # Returns a {Boolean}. 
  hasMultipleEditors: -> @refcount > 1

  # Internal:
  subscribeToFile: ->
    @file.on "contents-changed", =>
      if @isModified()
        @conflict = true
        @updateCachedDiskContents()
        @trigger "contents-conflicted"
      else
        @reload()

    @file.on "removed", =>
      @updateCachedDiskContents()
      @triggerModifiedStatusChanged(@isModified())

    @file.on "moved", =>
      @trigger "path-changed", this

  # Public: Reloads a file in the {EditSession}.
  #
  # Essentially, this performs a force read of the file.
  reload: ->
    @trigger 'will-reload'
    @updateCachedDiskContents()
    @setText(@cachedDiskContents)
    @triggerModifiedStatusChanged(false)
    @trigger 'reloaded'

  # Public: Rereads the contents of the file, and stores them in the cache.
  #
  # Essentially, this performs a force read of the file on disk.
  updateCachedDiskContents: ->
    @cachedDiskContents = @file.read()

  # Public: Gets the file's basename--that is, the file without any directory information.
  #
  # Returns a {String}.
  getBaseName: ->
    @file?.getBaseName()

  # Public: Retrieves the path for the file.
  #
  # Returns a {String}.
  getPath: ->
    @file?.getPath()

  # Public: Sets the path for the file.
  #
  # path - A {String} representing the new file path
  setPath: (path) ->
    return if path == @getPath()

    @file?.off()
    @file = new File(path)
    @file.read() if @file.exists()
    @subscribeToFile()

    @trigger "path-changed", this

  # Public: Retrieves the current buffer's file extension.
  #
  # Returns a {String}.
  getExtension: ->
    if @getPath()
      @getPath().split('/').pop().split('.').pop()
    else
      null

  # Public: Retrieves the cached buffer contents.
  #
  # Returns a {String}.
  getText: ->
    @cachedMemoryContents ?= @getTextInRange(@getRange())

  # Public: Replaces the current buffer contents.
  #
  # text - A {String} containing the new buffer contents.
  setText: (text) ->
    @change(@getRange(), text, normalizeLineEndings: false)

  # Public: Gets the range of the buffer contents.
  #
  # Returns a new {Range}, from `[0, 0]` to the end of the buffer.
  getRange: ->
    new Range([0, 0], [@getLastRow(), @getLastLine().length])

  # Public: Given a range, returns the lines of text within it.
  #
  # range - A {Range} object specifying your points of interest
  #
  # Returns a {String} of the combined lines.
  getTextInRange: (range) ->
    range = @clipRange(range)
    if range.start.row == range.end.row
      return @lineForRow(range.start.row)[range.start.column...range.end.column]

    multipleLines = []
    multipleLines.push @lineForRow(range.start.row)[range.start.column..] # first line
    multipleLines.push @lineEndingForRow(range.start.row)
    for row in [range.start.row + 1...range.end.row]
      multipleLines.push @lineForRow(row) # middle lines
      multipleLines.push @lineEndingForRow(row)
    multipleLines.push @lineForRow(range.end.row)[0...range.end.column] # last line

    return multipleLines.join ''

  # Public: Gets all the lines in a file.
  #
  # Returns an {Array} of {String}s.
  getLines: ->
    @lines

  # Public: Given a row, returns the line of text.
  #
  # row - A {Number} indicating the row.
  #
  # Returns a {String}.
  lineForRow: (row) ->
    @lines[row]

  lineEndingForRow: (row) ->
    @lineEndings[row] unless row is @getLastRow()

  suggestedLineEndingForRow: (row) ->
    @lineEndingForRow(row) ? @lineEndingForRow(row - 1)

  # Public: Given a row, returns the length of the line of text.
  #
  # row - A {Number} indicating the row.
  #
  # Returns a {Number}.
  lineLengthForRow: (row) ->
    @lines[row].length

  lineEndingLengthForRow: (row) ->
    (@lineEndingForRow(row) ? '').length

  # Public: Given a buffer row, this retrieves the range for that line.
  #
  # row - A {Number} identifying the row
  # options - A hash with one key, `includeNewline`, which specifies whether you 
  #           want to include the trailing newline
  #
  # Returns a {Range}.
  rangeForRow: (row, { includeNewline } = {}) ->
    if includeNewline and row < @getLastRow()
      new Range([row, 0], [row + 1, 0])
    else
      new Range([row, 0], [row, @lineLengthForRow(row)])

  # Public: Gets the number of lines in a file. 
  #
  # Returns a {Number}.
  getLineCount: ->
    @getLines().length

  # Public: Gets the row number of the last line.
  #
  # Returns a {Number}.
  getLastRow: ->
    @getLines().length - 1

  # Public: Finds the last line in the current buffer.
  #
  # Returns a {String}.
  getLastLine: ->
    @lineForRow(@getLastRow())

  # Public: Finds the last point in the current buffer.
  #
  # Returns a {Point} representing the last position.
  getEofPosition: ->
    lastRow = @getLastRow()
    new Point(lastRow, @lineLengthForRow(lastRow))

  characterIndexForPosition: (position) ->
    position = @clipPosition(position)

    index = 0
    for row in [0...position.row]
      index += @lineLengthForRow(row) + Math.max(@lineEndingLengthForRow(row), 1)
    index + position.column

  positionForCharacterIndex: (index) ->
    row = 0
    while index >= (lineLength = @lineLengthForRow(row) + Math.max(@lineEndingLengthForRow(row), 1))
      index -= lineLength
      row++

    new Point(row, index)

  # Public: Given a row, this deletes it from the buffer.
  #
  # row - A {Number} representing the row to delete
  deleteRow: (row) ->
    @deleteRows(row, row)

  # Public: Deletes a range of rows from the buffer.
  #
  # start - A {Number} representing the starting row
  # end - A {Number} representing the ending row
  deleteRows: (start, end) ->
    startPoint = null
    endPoint = null
    if end == @getLastRow()
      if start > 0
        startPoint = [start - 1, @lineLengthForRow(start - 1)]
      else
        startPoint = [start, 0]
      endPoint = [end, @lineLengthForRow(end)]
    else
      startPoint = [start, 0]
      endPoint = [end + 1, 0]

    @delete(new Range(startPoint, endPoint))

  # Public: Adds text to the end of the buffer.
  #
  # text - A {String} of text to add
  append: (text) ->
    @insert(@getEofPosition(), text)

  # Public: Adds text to a specific point in the buffer
  #
  # point - A {Point} in the buffer to insert into
  # text - A {String} of text to add
  insert: (point, text) ->
    @change(new Range(point, point), text)

  # Public: Deletes text from the buffer
  #
  # range - A {Range} whose text to delete
  delete: (range) ->
    @change(range, '')

  # Internal:
  change: (oldRange, newText, options) ->
    oldRange = Range.fromObject(oldRange)
    operation = new BufferChangeOperation({buffer: this, oldRange, newText, options})
    range = @pushOperation(operation)
    range

  clipPosition: (position) ->
    position = Point.fromObject(position)
    eofPosition = @getEofPosition()
    if position.isGreaterThan(eofPosition)
      eofPosition
    else
      row = Math.max(position.row, 0)
      column = Math.max(position.column, 0)
      column = Math.min(@lineLengthForRow(row), column)
      new Point(row, column)

  clipRange: (range) ->
    range = Range.fromObject(range)
    new Range(@clipPosition(range.start), @clipPosition(range.end))

  prefixAndSuffixForRange: (range) ->
    prefix: @lines[range.start.row][0...range.start.column]
    suffix: @lines[range.end.row][range.end.column..]

  # Internal:
  pushOperation: (operation, editSession) ->
    if @undoManager
      @undoManager.pushOperation(operation, editSession)
    else
      operation.do()

  # Internal:
  transact: (fn) ->  @undoManager.transact(fn)
  # Public: Undos the last operation.
  #
  # editSession - The {EditSession} associated with the buffer.
  undo: (editSession) -> @undoManager.undo(editSession)
  # Public: Redos the last operation.
  #
  # editSession - The {EditSession} associated with the buffer.
  redo: (editSession) -> @undoManager.redo(editSession)
  commit: -> @undoManager.commit()
  abort: -> @undoManager.abort()

  # Public: Saves the buffer.
  save: ->
    @saveAs(@getPath()) if @isModified()

  # Public: Saves the buffer at a specific path.
  #
  # path - The path to save at.
  saveAs: (path) ->
    unless path then throw new Error("Can't save buffer with no file path")

    @trigger 'will-be-saved'
    @setPath(path)
    @cachedDiskContents = @getText()
    @file.write(@getText())
    @triggerModifiedStatusChanged(false)
    @trigger 'saved'

  # Public: Identifies if the buffer was modified.
  #
  # Returns a {Boolean}.
  isModified: ->
    if @file
      @getText() != @cachedDiskContents
    else
      not @isEmpty()

  # Public: Identifies if a buffer is in a git conflict with `HEAD`.
  #
  # Returns a {Boolean}.
  isInConflict: -> @conflict

  # Public: Identifies if a buffer is empty.
  #
  # Returns a {Boolean}.
  isEmpty: -> @lines.length is 1 and @lines[0].length is 0

  getMarkers: ->
    _.values(@validMarkers)

  # Public: Retrieves the quantity of markers in a buffer.
  #
  # Returns a {Number}.
  getMarkerCount: ->
    _.size(@validMarkers)

  markRange: (range, options={}) ->
    marker = new BufferMarker(_.defaults({
      id: (@nextMarkerId++).toString()
      buffer: this
      range
    }, options))
    @validMarkers[marker.id] = marker
    marker.id

  markPosition: (position, options) ->
    @markRange([position, position], _.defaults({noTail: true}, options))

  destroyMarker: (id) ->
    delete @validMarkers[id]
    delete @invalidMarkers[id]

  getMarkerPosition: (args...) ->
    @getMarkerHeadPosition(args...)

  setMarkerPosition: (args...) ->
    @setMarkerHeadPosition(args...)

  getMarkerHeadPosition: (id) ->
    @validMarkers[id]?.getHeadPosition()

  setMarkerHeadPosition: (id, position, options) ->
    @validMarkers[id]?.setHeadPosition(position)

  getMarkerTailPosition: (id) ->
    @validMarkers[id]?.getTailPosition()

  setMarkerTailPosition: (id, position, options) ->
    @validMarkers[id]?.setTailPosition(position)

  getMarkerRange: (id) ->
    @validMarkers[id]?.getRange()

  setMarkerRange: (id, range, options) ->
    @validMarkers[id]?.setRange(range, options)

  placeMarkerTail: (id) ->
    @validMarkers[id]?.placeTail()

  clearMarkerTail: (id) ->
    @validMarkers[id]?.clearTail()

  isMarkerReversed: (id) ->
    @validMarkers[id]?.isReversed()

  isMarkerRangeEmpty: (id) ->
    @validMarkers[id]?.isRangeEmpty()

  observeMarker: (id, callback) ->
    @validMarkers[id]?.observe(callback)

  markersForPosition: (bufferPosition) ->
    bufferPosition = Point.fromObject(bufferPosition)
    ids = []
    for id, marker of @validMarkers
      ids.push(id) if marker.containsPoint(bufferPosition)
    ids

  matchesInCharacterRange: (regex, startIndex, endIndex) ->
    text = @getText()
    matches = []

    regex.lastIndex = startIndex
    while match = regex.exec(text)
      matchLength = match[0].length
      matchStartIndex = match.index
      matchEndIndex = matchStartIndex + matchLength

      if matchEndIndex > endIndex
        regex.lastIndex = 0
        if matchStartIndex < endIndex and submatch = regex.exec(text[matchStartIndex...endIndex])
          submatch.index = matchStartIndex
          matches.push submatch
        break

      matchEndIndex++ if matchLength is 0
      regex.lastIndex = matchEndIndex
      matches.push match

    matches

  # Public: Scans for text in the buffer, calling a function on each match.
  #
  # regex - A {RegExp} representing the text to find
  # iterator - A {Function} that's called on each match
  scan: (regex, iterator) ->
    @scanInRange(regex, @getRange(), iterator)

  # Public: Scans for text in a given range, calling a function on each match.
  #
  # regex - A {RegExp} representing the text to find
  # range - A {Range} in the buffer to search within
  # iterator - A {Function} that's called on each match
  # reverse - A {Boolean} indicating if the search should be backwards (default: `false`)
  scanInRange: (regex, range, iterator, reverse=false) ->
    range = @clipRange(range)
    global = regex.global
    flags = "gm"
    flags += "i" if regex.ignoreCase
    regex = new RegExp(regex.source, flags)

    startIndex = @characterIndexForPosition(range.start)
    endIndex = @characterIndexForPosition(range.end)

    matches = @matchesInCharacterRange(regex, startIndex, endIndex)
    lengthDelta = 0

    keepLooping = null
    replacementText = null
    stop = -> keepLooping = false
    replace = (text) -> replacementText = text

    matches.reverse() if reverse
    for match in matches
      matchLength = match[0].length
      matchStartIndex = match.index
      matchEndIndex = matchStartIndex + matchLength

      startPosition = @positionForCharacterIndex(matchStartIndex + lengthDelta)
      endPosition = @positionForCharacterIndex(matchEndIndex + lengthDelta)
      range = new Range(startPosition, endPosition)
      keepLooping = true
      replacementText = null
      iterator({match, range, stop, replace })

      if replacementText?
        @change(range, replacementText)
        lengthDelta += replacementText.length - matchLength unless reverse

      break unless global and keepLooping

  # Public: Scans for text in a given range _backwards_, calling a function on each match.
  #
  # regex - A {RegExp} representing the text to find
  # range - A {Range} in the buffer to search within
  # iterator - A {Function} that's called on each match
  backwardsScanInRange: (regex, range, iterator) ->
    @scanInRange regex, range, iterator, true

  # Public: Given a row, identifies if it is blank.
  #
  # row - A row {Number} to check
  #
  # Returns a {Boolean}.
  isRowBlank: (row) ->
    not /\S/.test @lineForRow(row)

  # Public: Given a row, this finds the next row above it that's empty.
  #
  # startRow - A {Number} identifying the row to start checking at
  #
  # Returns the row {Number} of the first blank row.
  # Returns `null` if there's no other blank row.
  previousNonBlankRow: (startRow) ->
    return null if startRow == 0

    startRow = Math.min(startRow, @getLastRow())
    for row in [(startRow - 1)..0]
      return row unless @isRowBlank(row)
    null

  # Public: Given a row, this finds the next row that's blank.
  #
  # startRow - A row {Number} to check
  #
  # Returns the row {Number} of the next blank row.
  # Returns `null` if there's no other blank row.
  nextNonBlankRow: (startRow) ->
    lastRow = @getLastRow()
    if startRow < lastRow
      for row in [(startRow + 1)..lastRow]
        return row unless @isRowBlank(row)
    null

  # Public: Identifies if the buffer has soft tabs anywhere.
  #
  # Returns a {Boolean},
  usesSoftTabs: ->
    for line in @getLines()
      if match = line.match(/^\s/)
        return match[0][0] != '\t'
    undefined

  # Public: Checks out the current `HEAD` revision of the file.
  checkoutHead: ->
    path = @getPath()
    return unless path
    git?.checkoutHead(path)

  # Internal:
  scheduleModifiedEvents: ->
    clearTimeout(@stoppedChangingTimeout) if @stoppedChangingTimeout
    stoppedChangingCallback = =>
      @stoppedChangingTimeout = null
      modifiedStatus = @isModified()
      @trigger 'contents-modified', modifiedStatus
      @triggerModifiedStatusChanged(modifiedStatus)
    @stoppedChangingTimeout = setTimeout(stoppedChangingCallback, @stoppedChangingDelay)

  # Internal:
  triggerModifiedStatusChanged: (modifiedStatus) ->
    return if modifiedStatus is @previousModifiedStatus
    @previousModifiedStatus = modifiedStatus
    @trigger 'modified-status-changed', modifiedStatus

  # Public: Checks to see if a file exists.
  #
  # Returns a {Boolean}.
  fileExists: ->
    @file? && @file.exists()

  # Internal:
  logLines: (start=0, end=@getLastRow())->
    for row in [start..end]
      line = @lineForRow(row)
      console.log row, line, line.length

  # Internal:
  getDebugSnapshot: ->
    lines = ['Buffer:']
    for row in [0..@getLastRow()]
      lines.push "#{row}: #{@lineForRow(row)}"
    lines.join('\n')

_.extend(Buffer.prototype, EventEmitter)
