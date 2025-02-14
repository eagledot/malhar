################################################################################


import strutils
import math
import unicode

# NOTE: Donot change, unless you know what you are doing.
const
    CODE_SIZE = 32
    TABLE_ARRAY_SIZE = 256
    RANGE_LVALUE = 256
    RANGE_QRATIO = 16
    TLSH_CHECKSUM_LENGTH = 1       # 1 byte
    SLIDING_WND_SIZE = 5
    BUCKETS = 256                      # Donot change it.
    EFF_BUCKETS = 128                  # play with it, but 128 is good.
    RNG_SIZE = 5

    LOG_1_5 = 0.4054651'f32
    LOG_1_3 = 0.26236426'f32
    LOG_1_1 = 0.095310180'f32

proc RNG_IDX(i:int):int {.inline.}=
    return (i + RNG_SIZE) mod RNG_SIZE

proc l_capturing(length:int):int =
    var i = 0
    if length <= 656:
        i = int(ln(length.float32) / LOG_1_5)
    elif length <= 3199:
        i = int((ln(length.float32) / LOG_1_3) - 8.72777)
    else:
        i = int((ln(length.float32) / LOG_1_1 ) - 62.5472)
    
    return (i and 0xff)

proc swap_byte(i:uint8):uint8 {.inline.} = 
    # seemed redundant as we use it for first 3 bytes in generation, and then call it again while comparison
    # swap lower and upper half of a byte.
    result = 0'u8
    result = ((i and 0xf0) shr 4) and 0x0f
    result = result or (((i and 0x0f) shl 4) and 0xf0)
    return result

# a look-up table, more elegant would be to generate at compileTime, but compiler complants,rightly so about being discontinuous!
# we can put some dummy values .. but later.. for (not in g-z)
var lookupTable:array[127, uint8]
const something = "abcdefABCDEF0123456789"
for i in 0..<len(something):
    lookupTable[ord(something[i])] = fromHex[uint8](something[i..<i+1])

# uint8 to hex mapping
var lookupTable2:array[256, string]
for i in 0..<len(lookupTable2):
    lookupTable2[uint8(i)] = toHex(uint8(i), 2)

const
    V_TABLE = [
    1'u8, 87, 49, 12, 176, 178, 102, 166, 121, 193, 6, 84, 249, 230, 44, 163,
    14, 197, 213, 181, 161, 85, 218, 80, 64, 239, 24, 226, 236, 142, 38, 200,
    110, 177, 104, 103, 141, 253, 255, 50, 77, 101, 81, 18, 45, 96, 31, 222,
    25, 107, 190, 70, 86, 237, 240, 34, 72, 242, 20, 214, 244, 227, 149, 235,
    97, 234, 57, 22, 60, 250, 82, 175, 208, 5, 127, 199, 111, 62, 135, 248,
    174, 169, 211, 58, 66, 154, 106, 195, 245, 171, 17, 187, 182, 179, 0, 243,
    132, 56, 148, 75, 128, 133, 158, 100, 130, 126, 91, 13, 153, 246, 216, 219,
    119, 68, 223, 78, 83, 88, 201, 99, 122, 11, 92, 32, 136, 114, 52, 10,
    138, 30, 48, 183, 156, 35, 61, 26, 143, 74, 251, 94, 129, 162, 63, 152,
    170, 7, 115, 167, 241, 206, 3, 150, 55, 59, 151, 220, 90, 53, 23, 131,
    125, 173, 15, 238, 79, 95, 89, 16, 105, 137, 225, 224, 217, 160, 37, 123,
    118, 73, 2, 157, 46, 116, 9, 145, 134, 228, 207, 212, 202, 215, 69, 229,
    27, 188, 67, 124, 168, 252, 42, 4, 29, 108, 21, 247, 19, 205, 39, 203,
    233, 40, 186, 147, 198, 192, 155, 33, 164, 191, 98, 204, 165, 180, 117, 76,
    140, 36, 210, 172, 41, 54, 159, 8, 185, 232, 113, 196, 231, 47, 146, 120,
    51, 65, 28, 144, 254, 221, 93, 189, 194, 139, 112, 43, 71, 109, 184, 209
    ]

proc generateTable():array[TABLE_ARRAY_SIZE * TABLE_ARRAY_SIZE, uint8]=
    for i in 0..<TABLE_ARRAY_SIZE:
        for j in 0..<TABLE_ARRAY_SIZE:
            var
                d = 0
                x = i
                y = j
                diff = 0
            
            d = abs(( x mod 4) - (y mod 4))
            diff += (int(d == 3)*6 + int(d != 3 ) * d ) # equivalent to (d == 3 ? 6:d)
            x = x div 4
            y = y div 4

            d = abs((x mod 4) - (y mod 4))
            diff += (int(d == 3)*6 + int(d != 3 )*d) # equivalent to (d == 3 ? 6:d)
            x = x div 4
            y = y div 4

            d = abs((x mod 4) - (y mod 4))
            diff += (int(d == 3)*6 + int(d != 3)*d) # equivalent to (d == 3 ? 6:d)
            x = x div 4
            y = y div 4

            d = abs((x mod 4) - (y mod 4))
            diff += (int(d == 3)*6 + int(d != 3 )*d) # equivalent to (d == 3 ? 6:d)

            assert diff >= 0 and diff <= 255
            result[i*TABLE_ARRAY_SIZE + j] = uint8(diff)

    return result

const BIT_PAIRWISE_DIFF_TABLE =  generateTable()

proc b_mapping(salt, i, j, k:uint8 ):uint8 =
    # to map the trigrams to buckets.
    # based on the PEARSON algorithm.

    var h = 0'u8
    h = V_TABLE[h xor salt]
    h = V_TABLE[h xor i]
    h = V_TABLE[h xor j]
    h = V_TABLE[h xor k]
    return h

proc mod_diff(x,y,R:int):int=
    var
        dl = y - x
        dr = x - y

    dl = int(y > x)*dl + int(y <= x)*(-1 * dl)
    dr = int(y > x)*(dr + R) + int(y <= x)*(-dr + R)
    return int(dl > dr)*dr + int(dl <= dr)*dl

proc getQLo(Q:uint8):uint8 {.inline.} =          # get lower half
    return Q and 0x0f
# template getQLo(Q:uint8):uint8 =
#     Q and 0x0f
proc getQHi(Q:uint8):uint8 {.inline.}= 
    return (Q and 0xf0) shr 4
proc setQHi(Q, x:uint8):uint8 {.inline.} =        # set upper half
    return (Q and 0x0f) or ((x and 0x0f) shl 4)
proc setQLo(Q, x:uint8):uint8 {.inline.} = 
    return (Q and 0xf0) or (x and 0x0f)



proc from_hex_mine(data:openArray[char], reverse:bool = false):array[CODE_SIZE, uint8] =

    assert len(data) mod 2 == 0
    assert len(data) == CODE_SIZE * 2

    # NOTE: technically it would not matter anyway, since result would used to index and then sum. final h_distance would be same anyway.
    for i in 0..<len(data) div 2:
        if not reverse:
            result[i] = lookupTable[ord(data[2*i])]*16 + lookupTable[ord(data[2*i+1])]
        else:
            result[CODE_SIZE - 1 - i] = lookupTable[ord(data[2*i])]*16 + lookupTable[ord(data[2*i+1])]
    return result

template h_distance(difference:var int, x:array[CODE_SIZE, uint8], y:array[CODE_SIZE, uint8])=
    for i in 0..<CODE_SIZE:
        difference +=  int(BIT_PAIRWISE_DIFF_TABLE[TABLE_ARRAY_SIZE*int(x[i]) + int(y[i])])

proc compare_tlsh_hash*(hash_1, hash_2:ptr UncheckedArray[uint8], leave_quartile_diff:bool = false, len_diff:bool = false):int {.inline.} = 
    # leave_quartile_diff:bool, meaning just don't consider the quartile distance.. (only h_distance), seems to work actually better !
    
    # this expects hashes as an array of bytes.
    # MUST CHECK that hash_1 and hash_2 length == CODE_SIZE +3 , half of hex representation.

    # No swapping, as not doing it in generation either
    let checksum_1 = hash_1[0]
    let checksum_2 = hash_2[0]

    let
        lValue_1 = hash_1[1]
        lValue_2 = hash_2[1]
    let
        qValue_1 = hash_1[2]
        qValue_2 = hash_2[2]

    var diff = 0
    if(len_diff):
        let ldiff = mod_diff(int(lValue_1), int(lValue_2), int(RANGE_LVALUE))
        if(ldiff == 0):
            diff = 0
        elif (ldiff == 1):
            diff = 1
        else:
            diff += ldiff * 12
    
    let q1diff = mod_diff(int(getQLo(qValue_1)), int(getQLo(qValue_2)), int(RANGE_QRATIO))
    if (q1diff <= 1):
        diff += q1diff
    else:
        # diff += (q1diff - 1)*12
        diff += (q1diff - 1)*1          # instead of 12 keep it 2, 12 was suggested for longer patterns! for us 2 or even 1 is ok..

    let q2diff = mod_diff(int(getQHi(qValue_1)), int(getQHi(qValue_2)), int(RANGE_QRATIO))
    if (q2diff <= 1):
        diff += q2diff
    else:
        # diff += (q2diff - 1)*12
        diff += (q2diff - 1)*1      # instead of 12 keep it 2, 12 was suggested for longer patterns! for us 2 or even 1 is ok..

    if checksum_1 != checksum_2:
        diff += 1
    
    # NOTE: technically it would not matter anyway, since result would used to index and then sum. final h_distance would be same anyway.
    var tmpCode_1:array[CODE_SIZE, uint8]
    var tmpCode_2:array[CODE_SIZE, uint8]
    
  
    # populate tmpCode_1, NOTE: i am assuming hash was reversed, but doesn't matter much.. SEE from_hex_mine, which was earlier used.
    let offset = 3
    for i in 0..<CODE_SIZE:
        tmpCode_1[CODE_SIZE - i - 1] = hash_1[offset + i]
        tmpCode_2[CODE_SIZE - i - 1] = hash_2[offset + i] 
    
    if leave_quartile_diff:
        diff = 0         # don't include the quartil difference!
    h_distance(diff, tmpCode_1, tmpCode_2)
    return diff

proc partition(x: var array[EFF_BUCKETS, uint32], left, right:int):int=
    if left == right:
        return left
    if (left + 1 == right):
        if x[left] > x[right]:
            # swap
            let tmp = x[left]
            x[left] = x[right]
            x[right] = tmp
        return left
    
    var
        ret =  left
        pivot = (left + right) shr 1
        val = x[pivot]
    
    for i in left..<right:
        if x[i] < val:
            # swap
            var tmp = x[ret]
            x[ret] = x[i]
            x[i] = tmp
            ret += 1
    
    x[right] = x[ret]
    x[ret] = val

    return ret

proc toUint8Hash*(hash_hex:string):seq[uint8]=
    # NOTE: just for convenience.. use toUint8Hash for hot loops with manually managed memory!
    result = newSeq[uint8](CODE_SIZE  + 3)
    for i in 0..<(CODE_SIZE + 3):
        result[i] = lookupTable[ord(hash_hex[2*i])]*16 + lookupTable[ord(hash_hex[2*i + 1])]
    return result

template toUint8Hash(hash_u8:ptr UncheckedArray[uint8], hash_hex:string)=
    # helper to generate uint8 values from hex encoded hash!
    for i in 0..<CODE_SIZE+3:
        hash_u8[i] = lookupTable[ord(hash_hex[2*i])]*16 + lookupTable[ord(hash_hex[2*i + 1])]

proc compare_tlsh_hash*(hash_1, hash_2:string, len_diff:bool = false):int = 
    # Inputs: hash_1, hash_2 are hex encoded HASH representation
    doAssert len(hash_1) == len(hash_2) and len(hash_1) ==  (CODE_SIZE + 3) * 2  # Twice, as byte takes 2 chars.

    var
        hash_1_arr:array[CODE_SIZE + 3 , uint8]
        hash_2_arr:array[CODE_SIZE + 3 , uint8]
    
    let 
        addr_1 = cast[ptr UncheckedArray[uint8]](addr(hash_1_arr[0]))
        addr_2 = cast[ptr UncheckedArray[uint8]](addr(hash_2_arr[0]))

    toUint8Hash(addr_1, hash_1)
    toUint8Hash(addr_2, hash_2)

    return compare_tlsh_hash(
            addr_1,
            addr_2,
            len_diff = len_diff)

proc generate_tlsh_hash*(data:string):tuple[flag:bool, hash:string] =

    # returns a flag, and hex encoded representation of TLSH hash. flag indicates, if hash is good enough to be used. if true, then yes, otherwise not enough variation was detected in the data passed .
    var
        checksum_array:array[TLSH_CHECKSUM_LENGTH, uint8]
        slide_window:array[SLIDING_WND_SIZE, uint8]
        a_bucket_array:array[BUCKETS, uint32]
        lsh_code:array[CODE_SIZE, uint8]

    let data_array{.cursor.} = data # using cursor, in case compiler doesn't infer that it is just a temporary read, I COMPARE `cursor`to a SHALLOW like pragama, copying only whats on stack, hence no `deepcopying` is involved for `assign` semantics!
    let data_length = len(data_array)

    var j = data_length mod RNG_SIZE
    var fed_length = 0

    var count  = 0
    for i in 0..<data_length:
        slide_window[j] = uint8(data_array[i])

        if (fed_length >= 4):
            var
                j_1 = RNG_IDX(j - 1)
                j_2 = RNG_IDX(j - 2)
                j_3 = RNG_IDX(j - 3)
                j_4 = RNG_IDX(j - 4)

            for k in 0..<TLSH_CHECKSUM_LENGTH:
                let salt_idx = 0*int(k == 0) + int(k != 0)*int(checksum_array[max(k - 1,0)])

                checksum_array[k] = b_mapping(
                    salt = uint8(salt_idx),
                    i = slide_window[j],
                    j = slide_window[j_1],
                    k = checksum_array[k]
                )
            
                var r = b_mapping(2, slide_window[j], slide_window[j_1], slide_window[j_2])
                r = b_mapping(2, slide_window[j], slide_window[j_1], slide_window[j_2])
                r = b_mapping(2, slide_window[j], slide_window[j_1], slide_window[j_2])

                a_bucket_array[r] += 1
                r = b_mapping(3, slide_window[j], slide_window[j_1], slide_window[j_3])
                a_bucket_array[r] += 1
                r = b_mapping(5, slide_window[j], slide_window[j_2], slide_window[j_3])
                a_bucket_array[r] += 1
                r = b_mapping(7, slide_window[j], slide_window[j_2], slide_window[j_4])
                a_bucket_array[r] += 1
                r = b_mapping(11, slide_window[j], slide_window[j_1], slide_window[j_4])
                a_bucket_array[r] += 1
                r = b_mapping(13, slide_window[j], slide_window[j_3], slide_window[j_4])
                a_bucket_array[r] += 1

                inc count
        
        fed_length += 1
        j = RNG_IDX(j + 1)
    
        
    
    # data_length += data_length

    # Find quartiles.
    var
        q0:uint32= 0
        q1:uint32 = 0
        q2:uint32 = 0
        q3:uint32 = 0

    var
        shortcut_left:array[EFF_BUCKETS, uint32]
        shortcut_right:array[EFF_BUCKETS, uint32]
        spl = 0
        spr = 0
        p1 = EFF_BUCKETS div 4 - 1
        p2 = EFF_BUCKETS div 2 - 1
        p3 = EFF_BUCKETS - (EFF_BUCKETS div 4) - 1

    var bucket_copy:array[EFF_BUCKETS, uint32]       
    for i in 0..<EFF_BUCKETS:
        bucket_copy[i] = a_bucket_array[i]
    
    var
        end_idx = EFF_BUCKETS - 1
        l = 0
        r = end_idx
    
    # find q2.
    while true:
        let ret = partition(bucket_copy, l, r) # bucket_copy is updated in place.
        if ret > p2:
            r = ret - 1
            shortcut_right[spr] = uint32(ret)
            spr += 1
        elif ret <  p2:
            l = ret + 1
            shortcut_left[spl] = uint32(ret)
            spl += 1
        else:
            q2 = bucket_copy[p2]
            break

    shortcut_left[spl] = uint32(p2 - 1)
    shortcut_left[spr] = uint32(p2 + 1)

    # finding q1
    l = 0
    for i in 0..<(spl + 1):
        r = int(shortcut_left[i])
        if r > p1:
            while true:
                let ret = partition(bucket_copy, l, r)
                if ret > p1:
                    r = ret - 1
                elif ret < p1:
                    l = ret + 1
                else:
                    q1 = bucket_copy[p1]
                    break
        
        elif r < p1:
            l = r
        else:
            q1 = bucket_copy[p1]
            break

    # find q3:
    r = end_idx
    for i in 0..<spr+1:
        l = int(shortcut_left[i])
        if l < p3:
            while true:
                let ret =  partition(bucket_copy, l, r)
                if (ret > p3):
                    r = ret - 1
                elif ret < p3:
                    l = ret + 1
                else:
                    q3 = bucket_copy[p3]
                    break
            break
        elif l > p3:
            r = l
        else:
            q3 = bucket_copy[p3]
            break

    var nonzero = 0
    for i in 0..<CODE_SIZE:
        for j in 0..<4:
            if a_bucket_array[4*i + j] > 0:
                nonzero += 1

    var FLAG = true
    if (nonzero <= 4 * (CODE_SIZE div 2)):
        FLAG = false
        echo "Warning: not enough variation"
    
    for i in 0..<CODE_SIZE:
        var h = 0'u8
        for j in 0..<4:
            var k = a_bucket_array[4*i + j]
            if q3 < k:
                h += (3'u8 shl uint8(j*2))
            elif q2 < k:
                h += (2'u8 shl uint8(j*2))
            elif q1 < k:
                h += (1'u8 shl uint8(j*2))

        # tmp_code[i] = h
        lsh_code[i] = h
    
    let lValue = l_capturing(data_length)

    let tmp_q3 = max(1, int(q3))
    var Q = 0'u8
    Q = setQLo(Q, uint8(((int(q1) * 100) div tmp_q3) mod 16))
    Q = setQHi(Q, uint8(((int(q2) * 100) div tmp_q3) mod 16))
    var lsh_code_valid = true


    #checksum hex representation
    var hash_hexDigest = ""
    for k in 0..<TLSH_CHECKSUM_LENGTH:
        # hash_hexDigest = hash_hexDigest & toHex[uint8](swap_byte(checksum_array[k]), 2)
        # hash_hexDigest = hash_hexDigest & toHex[uint8](checksum_array[k], 2)
        hash_hexDigest = hash_hexDigest & lookupTable2[checksum_array[k]]
    
    # l value hex representation
    # hash_hexDigest = hash_hexDigest & toHex(swap_byte(uint8(lValue)))
    # hash_hexDigest = hash_hexDigest & toHex[uint8](uint8(lValue), 2)
    hash_hexDigest = hash_hexDigest & lookupTable2[lValue]
        
    # q value hex representation
    # hash_hexDigest = hash_hexDigest & toHex(swap_byte(uint8(Q)))
    # hash_hexDigest = hash_hexDigest & toHex[uint8](uint8(Q), 2)
    hash_hexDigest = hash_hexDigest & lookupTable2[Q]

    for i in countdown(CODE_SIZE - 1, 0): # countdown/countup should not matter, as long as all hashes follows a common order!
        hash_hexDigest = hash_hexDigest & lookupTable2[lsh_code[i]]
    
    # TODO: return lsh_code.
    result.flag = FLAG
    result.hash = hash_hexDigest
    return result
